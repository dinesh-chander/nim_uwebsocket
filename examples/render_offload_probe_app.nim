import std/[asyncdispatch, atomics, strutils, os]
import ../nim_express/src/nim_express

var serialCounter: Atomic[int64]

type
  SharedPayload = object
    data: pointer
    len: int

proc nextSerial(): int64 {.inline.} =
  serialCounter.fetchAdd(1'i64, moRelaxed) + 1'i64

proc queryInt(req: Request, key: string, defaultValue, minValue, maxValue: int): int =
  result = defaultValue
  try:
    result = parseInt(req.queryParam(key, $defaultValue))
  except ValueError:
    discard
  result = max(minValue, min(maxValue, result))

proc buildHtmlPayload(serial: int64, extraBytes: int): string {.gcsafe.} =
  result = newStringOfCap(max(256, extraBytes + 128))
  result.add("<!doctype html><html><body><h1>render probe</h1><p>serial=")
  result.add($serial)
  result.add("</p><p>")
  if extraBytes > 0:
    result.add(repeat('x', extraBytes))
  result.add("</p></body></html>")

proc buildSharedPayload(serial: int64, extraBytes: int): SharedPayload {.gcsafe.} =
  let raw = buildHtmlPayload(serial, extraBytes)
  if raw.len == 0:
    return
  result.len = raw.len
  result.data = allocShared(result.len)
  if result.data == nil:
    raise newException(OutOfMemDefect, "could not allocate shared payload")
  copyMem(result.data, unsafeAddr raw[0], result.len)

proc takeSharedPayload(payload: var SharedPayload): string =
  if payload.data == nil or payload.len <= 0:
    if payload.data != nil:
      deallocShared(payload.data)
      payload.data = nil
    payload.len = 0
    return ""
  result = newString(payload.len)
  copyMem(addr result[0], payload.data, payload.len)
  deallocShared(payload.data)
  payload.data = nil
  payload.len = 0

proc checksumWork(iterations: int): int {.gcsafe.} =
  var checksum = 0
  for i in 0 ..< iterations:
    checksum = (checksum + ((i * 31) xor (i shr 3))) and 0x7fffffff
  checksum

let app = newExpressApp()

app.getAsync("/health") do (_: Request, res: Response) {.async.}:
  res.send("ok")

app.getAsync("/render-sync") do (req: Request, res: Response) {.async.}:
  let extraBytes = queryInt(req, "bytes", 1024, 0, 16 * 1024)
  let serial = nextSerial()
  res.html(buildHtmlPayload(serial, extraBytes))

app.getAsync("/offload-int") do (req: Request, res: Response) {.async.}:
  let extraBytes = queryInt(req, "bytes", 1024, 0, 16 * 1024)
  let serial = nextSerial()
  let count = await runOffload(len(buildHtmlPayload(serial, extraBytes)))
  if req.aborted():
    return
  res.send($count)

app.getAsync("/offload-int-pure") do (req: Request, res: Response) {.async.}:
  let iterations = queryInt(req, "iterations", 2000, 1, 2_000_000)
  let checksum = await runOffload(checksumWork(iterations))
  if req.aborted():
    return
  res.send($checksum)

app.getAsync("/offload-string") do (req: Request, res: Response) {.async.}:
  let extraBytes = queryInt(req, "bytes", 1024, 0, 16 * 1024)
  let serial = nextSerial()
  let body = await runOffload(buildHtmlPayload(serial, extraBytes))
  if req.aborted():
    return
  res.html(body)

app.getAsync("/offload-shared") do (req: Request, res: Response) {.async.}:
  let extraBytes = queryInt(req, "bytes", 1024, 0, 16 * 1024)
  let serial = nextSerial()
  var body = await runOffload(buildSharedPayload(serial, extraBytes))
  if req.aborted():
    if body.data != nil:
      deallocShared(body.data)
    return
  res.html(body.takeSharedPayload())

let port = parseInt(getEnv("PORT", "3000"))
echo "render_offload_probe_app listening on http://127.0.0.1:", port
app.run(port)
