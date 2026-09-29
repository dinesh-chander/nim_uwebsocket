import std/[atomics, json, os, random, strutils]
import ../nim_express/src/nim_express

const
  PayloadPoolSize = 4096
  DispatchIntervalMs = 10
  TimerWheelSlots = 25
  MaxSendDelayMs = 250
  WsSendBufSize = 2048
  WsRecvBufSize = 1024

  SlabCapacity = 4096
  HashMask = (1 shl 17) - 1

  Names = [
    "Aarav", "Mia", "Noah", "Isha", "Liam", "Olivia", "Ethan", "Ava",
    "Arjun", "Sophia", "Lucas", "Emma", "Kabir", "Amelia", "Mason", "Isla"
  ]
  Ages = [23, 27, 29, 31, 34, 38, 41, 45, 49, 52]
  Addresses = [
    "12 Riverwalk Ave", "44 Cedar Lane", "89 Market Street", "17 Hillcrest Road",
    "205 Harbor Drive", "88 Willow Park", "63 Kingfisher Way", "314 Orchard Close"
  ]
  Cities = [
    "San Francisco", "New York", "Austin", "Seattle", "Chicago", "Boston", "Denver", "Miami"
  ]
  Locations = [
    "Downtown", "Midtown", "Waterfront", "Old Town", "North Side", "South Park", "Tech Park", "City Center"
  ]
  Longitudes = [-122.4194, -74.0060, -97.7431, -122.3321, -87.6298, -71.0589, -104.9903, -80.1918]
  Lattitudes = [37.7749, 40.7128, 30.2672, 47.6062, 41.8781, 42.3601, 39.7392, 25.7617]
  ProfessionalTypes = [
    "engineer", "designer", "doctor", "teacher", "lawyer", "architect", "analyst", "manager"
  ]

type
  WsRandomObject = object
    name: string
    age: int
    address: string
    city: string
    location: string
    longitude: float64
    lattitude: float64
    professionalType: string

  PreparedPayload = object
    value: WsRandomObject
    json: string

  ClientSlot = object
    ws: WebSocket
    wheelSlot: int
    generation: uint32
    active: bool

  PtrHashEntry = object
    key: uint
    slotIdx: int32
    occupied: bool

var
  slab: seq[ClientSlot]
  freeList: seq[int32]
  slabCount = 0

  ptrHash: seq[PtrHashEntry]

  payloadPool: seq[PreparedPayload] = @[]
  acceptedConnections = 0'i64
  closedConnections = 0'i64
  messagesSent = 0'i64
  timerWheel: array[TimerWheelSlots, seq[int32]]
  currentWheelTick = 0
  globalGeneration = 0'u32

when compileOption("threads"):
  type
    FeedWakeState = object
      server: HttpServer
      intervalMs: int
      running: Atomic[bool]

  var feedWakeState: FeedWakeState
  var feedWakeThread: Thread[ptr FeedWakeState]

proc ptrHashProbe(key: uint): int {.inline.} =
  int((key xor (key shr 16)) and uint(HashMask))

proc ptrHashFind(key: uint): int32 {.inline.} =
  var i = ptrHashProbe(key)
  while ptrHash[i].occupied:
    if ptrHash[i].key == key:
      return ptrHash[i].slotIdx
    i = (i + 1) and HashMask
  -1

proc ptrHashInsert(key: uint, slotIdx: int32) {.inline.} =
  var i = ptrHashProbe(key)
  while ptrHash[i].occupied:
    if ptrHash[i].key == key:
      ptrHash[i].slotIdx = slotIdx
      return
    i = (i + 1) and HashMask
  ptrHash[i] = PtrHashEntry(key: key, slotIdx: slotIdx, occupied: true)

proc ptrHashDelete(key: uint) {.inline.} =
  var i = ptrHashProbe(key)
  while ptrHash[i].occupied:
    if ptrHash[i].key == key:
      ptrHash[i].occupied = false
      ptrHash[i].key = 0
      var j = (i + 1) and HashMask
      while ptrHash[j].occupied:
        let k = ptrHashProbe(ptrHash[j].key)
        let wrap = if j >= i: (k <= i or k > j) else: (k <= i and k > j)
        if wrap:
          ptrHash[i] = ptrHash[j]
          ptrHash[j].occupied = false
          ptrHash[j].key = 0
          i = j
        j = (j + 1) and HashMask
      return
    i = (i + 1) and HashMask

proc wsKey(ws: WebSocket): uint {.inline.} =
  cast[uint](ws)

proc scheduleWheelOffset(): int {.inline.} =
  rand(0 .. MaxSendDelayMs div DispatchIntervalMs)

proc randomFrom[T](values: openArray[T]): T {.inline.} =
  values[rand(0 ..< values.len)]

proc buildRandomObject(): WsRandomObject =
  result.name = randomFrom(Names)
  result.age = randomFrom(Ages)
  result.address = randomFrom(Addresses)
  result.city = randomFrom(Cities)
  result.location = randomFrom(Locations)
  result.longitude = randomFrom(Longitudes)
  result.lattitude = randomFrom(Lattitudes)
  result.professionalType = randomFrom(ProfessionalTypes)

proc objectToJson(value: WsRandomObject): string =
  result = newStringOfCap(192)
  result.add("{\"name\":\"")
  result.add(value.name)
  result.add("\",\"age\":")
  result.add($value.age)
  result.add(",\"address\":\"")
  result.add(value.address)
  result.add("\",\"city\":\"")
  result.add(value.city)
  result.add("\",\"location\":\"")
  result.add(value.location)
  result.add("\",\"longitude\":")
  result.add(formatFloat(value.longitude, ffDecimal, 4))
  result.add(",\"lattitude\":")
  result.add(formatFloat(value.lattitude, ffDecimal, 4))
  result.add(",\"professional_type\":\"")
  result.add(value.professionalType)
  result.add("\"}")

proc initPayloadPool() =
  payloadPool = newSeqOfCap[PreparedPayload](PayloadPoolSize)
  for _ in 0 ..< PayloadPoolSize:
    let value = buildRandomObject()
    payloadPool.add(PreparedPayload(value: value, json: objectToJson(value)))

proc setSmallSocketBuffers(ws: WebSocket) {.inline.} =
  ws.setWsSocketBufferSizes(WsSendBufSize, WsRecvBufSize)

proc allocSlot(): int32 {.inline.} =
  if freeList.len > 0:
    result = freeList[^1]
    freeList.setLen(freeList.len - 1)
  else:
    result = int32(slab.len)
    slab.add(ClientSlot())

proc addClient(ws: WebSocket) =
  let idx = allocSlot()
  inc globalGeneration
  let wheelOffset = scheduleWheelOffset()
  let slot = (currentWheelTick + wheelOffset) mod TimerWheelSlots
  slab[idx] = ClientSlot(ws: ws, wheelSlot: slot, generation: globalGeneration, active: true)
  ptrHashInsert(wsKey(ws), idx)
  timerWheel[slot].add(idx)
  inc slabCount
  inc acceptedConnections
  setSmallSocketBuffers(ws)

proc removeClient(ws: WebSocket) =
  let key = wsKey(ws)
  let idx = ptrHashFind(key)
  if idx < 0:
    return
  slab[idx].active = false
  slab[idx].ws = nil
  slab[idx].generation = 0
  ptrHashDelete(key)
  freeList.add(idx)
  dec slabCount
  inc closedConnections

var preparedCache: seq[PreparedWsMessage]
var preparedCacheUsed: seq[int32]

proc dispatchRandomObjects() =
  if slabCount == 0 or payloadPool.len == 0:
    return

  let bucket = currentWheelTick mod TimerWheelSlots
  currentWheelTick += 1

  let entries = timerWheel[bucket]
  var newBucket = newSeqOfCap[int32](entries.len div TimerWheelSlots + 16)
  var carry = newSeqOfCap[int32](entries.len)

  if preparedCache.len < payloadPool.len:
    preparedCache = newSeq[PreparedWsMessage](payloadPool.len)
  preparedCacheUsed.setLen(0)

  for clientIdx in entries:
    if clientIdx >= int32(slab.len):
      continue
    let cs = addr slab[clientIdx]
    if not cs.active or cs.ws == nil or not cs.ws.isOpen:
      continue
    let pidx = rand(0 ..< payloadPool.len)
    if preparedCache[pidx] == nil:
      preparedCache[pidx] = prepareWsMessage(payloadPool[pidx].json, false)
      preparedCacheUsed.add(int32(pidx))
    discard cs.ws.sendPrepared(preparedCache[pidx])
    inc messagesSent
    let nextSlot = (currentWheelTick - 1 + scheduleWheelOffset()) mod TimerWheelSlots
    cs.wheelSlot = nextSlot
    if nextSlot == bucket:
      newBucket.add(clientIdx)
    else:
      carry.add(clientIdx)

  for idx in preparedCacheUsed:
    preparedCache[idx] = nil

  timerWheel[bucket] = newBucket
  for ci in carry:
    let s = slab[ci].wheelSlot
    timerWheel[s].add(ci)

proc dispatchRandomObjectsDeferred() {.gcsafe.} =
  {.cast(gcsafe).}:
    dispatchRandomObjects()

when compileOption("threads"):
  proc feedWakeLoop(statePtr: ptr FeedWakeState) {.thread.} =
    while statePtr != nil and statePtr[].running.load(moAcquire):
      sleep(statePtr[].intervalMs)
      let server = statePtr[].server
      if server != nil:
        server.queueDeferredPreFromAnyThread(dispatchRandomObjectsDeferred)

  proc startFeedWakeLoop(server: HttpServer, intervalMs: int) =
    feedWakeState.server = server
    feedWakeState.intervalMs = intervalMs
    feedWakeState.running.store(true, moRelease)
    createThread(feedWakeThread, feedWakeLoop, addr feedWakeState)

proc statsJson(): JsonNode =
  %*{
    "currentConnections": slabCount,
    "acceptedConnections": acceptedConnections,
    "closedConnections": closedConnections,
    "messagesSent": messagesSent,
    "payloadPool": payloadPool.len,
    "dispatchIntervalMs": DispatchIntervalMs,
    "timerWheelSlots": TimerWheelSlots,
    "slabAllocated": slab.len,
    "freeListSize": freeList.len
  }

proc main() =
  randomize()
  initPayloadPool()
  slab = newSeqOfCap[ClientSlot](SlabCapacity)
  freeList = newSeqOfCap[int32](SlabCapacity div 4)
  ptrHash = newSeq[PtrHashEntry](HashMask + 1)
  for i in 0 ..< TimerWheelSlots:
    timerWheel[i] = newSeqOfCap[int32](SlabCapacity div TimerWheelSlots + 16)

  let app = newExpressApp()
  app.server.setWsCompressionEnabled(false)
  app.setWsIdleTimeout(180)
  app.setWsMaxBackpressure(8 * 1024 * 1024)

  var port = 3412
  try:
    port = parseInt(getEnv("PORT", "3412"))
  except ValueError:
    port = 3412

  app.get("/health") do (_: Request, res: Response):
    res.text("ok")

  app.get("/metrics") do (_: Request, res: Response):
    res.contentType("application/json; charset=utf-8")
    res.send(res.app.optimizationMetricsJson())

  app.get("/stats") do (_: Request, res: Response):
    res.json(statsJson())

  app.ws proc(_: WebSocket, _: string, _: bool) =
    discard

  app.onWsOpen proc(ws: WebSocket) =
    addClient(ws)

  app.onWsClose proc(ws: WebSocket) =
    removeClient(ws)

  app.listen(port) do (ok: bool):
    if ok:
      when compileOption("threads"):
        startFeedWakeLoop(app.server, DispatchIntervalMs)
      echo "ws_random_object_bench listening on http://127.0.0.1:", port
    else:
      quit(1)

when isMainModule:
  main()
