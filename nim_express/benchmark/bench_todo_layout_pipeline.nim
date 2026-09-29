import std/[os, strformat, strutils, times]

import ../examples/todo_sqlite_mvc/todo_model
import ../src/nim_express/json_builder

type
  LayoutKind = enum
    lkAll
    lkAoS
    lkSoA
    lkPrepared
    lkMaterialized

  BlobColumn = object
    data: string
    offsets: seq[int]
    lens: seq[int]

  TodoSoA = object
    ids: seq[int]
    completed: seq[uint8]
    titles: BlobColumn
    createdAts: BlobColumn

  TodoPrepared = object
    idTexts: BlobColumn
    completed: seq[uint8]
    titleJsons: BlobColumn
    createdJsons: BlobColumn
    exactCapacity: int

  TodoMaterialized = object
    rows: BlobColumn
    exactCapacity: int

  BenchResult = object
    name: string
    iterations: int
    elapsedMs: float
    checksum: int

proc msBetween(startedAt, endedAt: float): float {.inline.} =
  (endedAt - startedAt) * 1000.0

proc opsPerSec(iterations: int, elapsedMs: float): float {.inline.} =
  if elapsedMs <= 0.0:
    return 0.0
  iterations.float * 1000.0 / elapsedMs

proc printResult(result: BenchResult) =
  echo result.name
  echo "  iterations: ", result.iterations
  echo "  elapsed:    ", formatFloat(result.elapsedMs, ffDecimal, 2), " ms"
  echo "  throughput: ", formatFloat(opsPerSec(result.iterations, result.elapsedMs), ffDecimal, 0), " ops/s"
  echo "  checksum:   ", result.checksum

proc parseLayoutKind(value: string): LayoutKind =
  case value.normalize
  of "all":
    lkAll
  of "aos":
    lkAoS
  of "soa":
    lkSoA
  of "prepared", "soa-prepared":
    lkPrepared
  of "materialized", "rows":
    lkMaterialized
  else:
    quit("unknown layout kind: " & value, QuitFailure)

proc appendSlice(dst: var string, src: string, startPos, len: int) {.inline.} =
  if len <= 0:
    return
  let dstPos = dst.len
  dst.setLen(dstPos + len)
  when nimvm:
    for i in 0 ..< len:
      dst[dstPos + i] = src[startPos + i]
  else:
    copyMem(addr dst[dstPos], unsafeAddr src[startPos], len)

proc addBlob(col: var BlobColumn, value: string) =
  col.offsets.add(col.data.len)
  col.lens.add(value.len)
  col.data.add(value)

proc addQuotedSlice(builder: var JsonBuilder, src: string, startPos, len: int) =
  builder.buf.add('"')
  appendSlice(builder.buf, src, startPos, len)
  builder.buf.add('"')

proc addEscapedSlice(builder: var JsonBuilder, src: string, startPos, len: int) =
  let stop = startPos + len
  builder.buf.add('"')
  var copyStart = startPos
  var i = startPos

  template flushCopy() =
    if i > copyStart:
      appendSlice(builder.buf, src, copyStart, i - copyStart)

  while i < stop:
    let c = src[i]
    if (cast[uint8](c) and 0b1000_0000'u8) == 0'u8:
      case c
      of '"':
        flushCopy()
        builder.buf.add("\\\"")
        inc i
        copyStart = i
      of '\\':
        flushCopy()
        builder.buf.add("\\\\")
        inc i
        copyStart = i
      of '\n':
        flushCopy()
        builder.buf.add("\\n")
        inc i
        copyStart = i
      of '\r':
        flushCopy()
        builder.buf.add("\\r")
        inc i
        copyStart = i
      of '\t':
        flushCopy()
        builder.buf.add("\\t")
        inc i
        copyStart = i
      else:
        if ord(c) < 0x20:
          flushCopy()
          builder.buf.add("\\u00")
          const HexDigits = "0123456789abcdef"
          let code = ord(c)
          builder.buf.add(HexDigits[(code shr 4) and 0x0f])
          builder.buf.add(HexDigits[code and 0x0f])
          inc i
          copyStart = i
        else:
          inc i
    else:
      inc i

  flushCopy()
  builder.buf.add('"')

proc needsJsonEscape(src: string, startPos, len: int): bool =
  let stop = startPos + len
  for i in startPos ..< stop:
    let c = src[i]
    if c in {'"', '\\', '\n', '\r', '\t'} or ord(c) < 0x20:
      return true
  false

proc encodedJsonStringLen(src: string, startPos, len: int): int =
  result = 2
  let stop = startPos + len
  for i in startPos ..< stop:
    let c = src[i]
    case c
    of '"', '\\', '\n', '\r', '\t':
      result += 2
    else:
      if ord(c) < 0x20:
        result += 6
      else:
        inc result

proc appendTodoJson(builder: var JsonBuilder, todo: Todo) =
  builder.add("""{"id":""")
  builder.addInt(todo.id)
  builder.add(""","title":""")
  builder.addEscaped(todo.title)
  builder.add(""","completed":""")
  builder.addBool(todo.completed)
  builder.add(""","createdAt":""")
  builder.addEscaped(todo.createdAt)
  builder.add("}")

proc serializeAoS(todos: seq[Todo]): string =
  var builder = initJsonBuilder(16 + todos.len * 96)
  builder.add("""{"todos":[""")
  for i, todo in todos:
    if i > 0:
      builder.add(",")
    builder.appendTodoJson(todo)
  builder.add("]}")
  builder.finish()

proc buildSoA(todos: seq[Todo]): TodoSoA =
  result.ids = newSeqOfCap[int](todos.len)
  result.completed = newSeqOfCap[uint8](todos.len)
  result.titles.offsets = newSeqOfCap[int](todos.len)
  result.titles.lens = newSeqOfCap[int](todos.len)
  result.createdAts.offsets = newSeqOfCap[int](todos.len)
  result.createdAts.lens = newSeqOfCap[int](todos.len)
  for todo in todos:
    result.ids.add(todo.id)
    result.completed.add(if todo.completed: 1'u8 else: 0'u8)
    result.titles.addBlob(todo.title)
    result.createdAts.addBlob(todo.createdAt)

proc serializeSoA(soa: TodoSoA): string =
  var builder = initJsonBuilder(16 + soa.ids.len * 96)
  builder.add("""{"todos":[""")
  for i in 0 ..< soa.ids.len:
    if i > 0:
      builder.add(",")
    builder.add("""{"id":""")
    builder.addInt(soa.ids[i])
    builder.add(""","title":""")
    builder.addEscapedSlice(soa.titles.data, soa.titles.offsets[i], soa.titles.lens[i])
    builder.add(""","completed":""")
    builder.addBool(soa.completed[i] != 0)
    builder.add(""","createdAt":""")
    builder.addEscapedSlice(soa.createdAts.data, soa.createdAts.offsets[i], soa.createdAts.lens[i])
    builder.add("}")
  builder.add("]}")
  builder.finish()

proc buildPrepared(soa: TodoSoA): TodoPrepared =
  let rowCount = soa.ids.len
  result.idTexts.offsets = newSeqOfCap[int](rowCount)
  result.idTexts.lens = newSeqOfCap[int](rowCount)
  result.completed = newSeqOfCap[uint8](rowCount)
  result.titleJsons.offsets = newSeqOfCap[int](rowCount)
  result.titleJsons.lens = newSeqOfCap[int](rowCount)
  result.createdJsons.offsets = newSeqOfCap[int](rowCount)
  result.createdJsons.lens = newSeqOfCap[int](rowCount)
  result.exactCapacity = 11

  for i in 0 ..< rowCount:
    var idText = newStringOfCap(12)
    fastIntToStr(soa.ids[i], idText)
    result.idTexts.addBlob(idText)
    result.completed.add(soa.completed[i])

    let titleStart = soa.titles.offsets[i]
    let titleLen = soa.titles.lens[i]
    var titleJson = newStringOfCap(encodedJsonStringLen(soa.titles.data, titleStart, titleLen))
    titleJson.add('"')
    if needsJsonEscape(soa.titles.data, titleStart, titleLen):
      var tmp = initJsonBuilder(titleJson.capacity)
      tmp.addEscapedSlice(soa.titles.data, titleStart, titleLen)
      titleJson = tmp.finish()
    else:
      appendSlice(titleJson, soa.titles.data, titleStart, titleLen)
      titleJson.add('"')
    result.titleJsons.addBlob(titleJson)

    let createdStart = soa.createdAts.offsets[i]
    let createdLen = soa.createdAts.lens[i]
    var createdJson = newStringOfCap(encodedJsonStringLen(soa.createdAts.data, createdStart, createdLen))
    createdJson.add('"')
    if needsJsonEscape(soa.createdAts.data, createdStart, createdLen):
      var tmp = initJsonBuilder(createdJson.capacity)
      tmp.addEscapedSlice(soa.createdAts.data, createdStart, createdLen)
      createdJson = tmp.finish()
    else:
      appendSlice(createdJson, soa.createdAts.data, createdStart, createdLen)
      createdJson.add('"')
    result.createdJsons.addBlob(createdJson)

    result.exactCapacity += 34
    result.exactCapacity += idText.len
    result.exactCapacity += titleJson.len
    result.exactCapacity += createdJson.len
    result.exactCapacity += (if soa.completed[i] != 0: 4 else: 5)
    if i > 0:
      inc result.exactCapacity

proc serializePrepared(prepared: TodoPrepared): string =
  var builder = initJsonBuilder(prepared.exactCapacity)
  builder.add("""{"todos":[""")
  for i in 0 ..< prepared.idTexts.offsets.len:
    if i > 0:
      builder.add(",")
    builder.add("""{"id":""")
    appendSlice(builder.buf, prepared.idTexts.data, prepared.idTexts.offsets[i], prepared.idTexts.lens[i])
    builder.add(""","title":""")
    appendSlice(builder.buf, prepared.titleJsons.data, prepared.titleJsons.offsets[i], prepared.titleJsons.lens[i])
    builder.add(""","completed":""")
    builder.addBool(prepared.completed[i] != 0)
    builder.add(""","createdAt":""")
    appendSlice(builder.buf, prepared.createdJsons.data, prepared.createdJsons.offsets[i], prepared.createdJsons.lens[i])
    builder.add("}")
  builder.add("]}")
  builder.finish()

proc buildMaterialized(prepared: TodoPrepared): TodoMaterialized =
  let rowCount = prepared.idTexts.offsets.len
  result.rows.offsets = newSeqOfCap[int](rowCount)
  result.rows.lens = newSeqOfCap[int](rowCount)
  result.exactCapacity = 11
  for i in 0 ..< rowCount:
    let rowLen =
      34 +
      prepared.idTexts.lens[i] +
      prepared.titleJsons.lens[i] +
      prepared.createdJsons.lens[i] +
      (if prepared.completed[i] != 0: 4 else: 5)
    var row = newStringOfCap(rowLen)
    row.add("""{"id":""")
    appendSlice(row, prepared.idTexts.data, prepared.idTexts.offsets[i], prepared.idTexts.lens[i])
    row.add(""","title":""")
    appendSlice(row, prepared.titleJsons.data, prepared.titleJsons.offsets[i], prepared.titleJsons.lens[i])
    row.add(""","completed":""")
    row.add(if prepared.completed[i] != 0: "true" else: "false")
    row.add(""","createdAt":""")
    appendSlice(row, prepared.createdJsons.data, prepared.createdJsons.offsets[i], prepared.createdJsons.lens[i])
    row.add("}")
    result.rows.addBlob(row)
    result.exactCapacity += row.len
    if i > 0:
      inc result.exactCapacity

proc serializeMaterialized(materialized: TodoMaterialized): string =
  var builder = initJsonBuilder(materialized.exactCapacity)
  builder.add("""{"todos":[""")
  for i in 0 ..< materialized.rows.offsets.len:
    if i > 0:
      builder.add(",")
    appendSlice(builder.buf, materialized.rows.data, materialized.rows.offsets[i], materialized.rows.lens[i])
  builder.add("]}")
  builder.finish()

proc bench(name: string, iterations: int, producer: proc(): string {.nimcall.}): BenchResult =
  var checksum = 0
  let startedAt = epochTime()
  for _ in 0 ..< iterations:
    let payload = producer()
    inc checksum, payload.len
  let endedAt = epochTime()
  BenchResult(name: name, iterations: iterations, elapsedMs: msBetween(startedAt, endedAt), checksum: checksum)

when isMainModule:
  var iterations = 200_000
  var kind = lkAll
  if paramCount() >= 1:
    iterations = parseInt(paramStr(1))
  if paramCount() >= 2:
    kind = parseLayoutKind(paramStr(2))
  if iterations <= 0:
    quit("iterations must be > 0", QuitFailure)

  var todos = newSeqOfCap[Todo](128)
  for i in 0 ..< 128:
    let title =
      if (i mod 11) == 0:
        "todo-\"" & $i & "\\n-ship-serializer"
      else:
        "todo-" & $i & "-ship-serializer"
    todos.add(Todo(
      id: i + 1,
      title: title,
      completed: (i and 1) == 0,
      createdAt: "2026-03-13T10:00:00Z"
    ))

  let soa = buildSoA(todos)
  let prepared = buildPrepared(soa)
  let materialized = buildMaterialized(prepared)

  echo &"Benchmark iterations={iterations} kind={kind}"
  echo "Warming up..."
  if kind in {lkAll, lkAoS}:
    discard bench("todo list AoS", min(iterations, 2_000), proc(): string = serializeAoS(todos))
  if kind in {lkAll, lkSoA}:
    discard bench("todo list SoA", min(iterations, 2_000), proc(): string = serializeSoA(soa))
  if kind in {lkAll, lkPrepared}:
    discard bench("todo list SoA prepared", min(iterations, 2_000), proc(): string = serializePrepared(prepared))
  if kind in {lkAll, lkMaterialized}:
    discard bench("todo list materialized rows", min(iterations, 2_000), proc(): string = serializeMaterialized(materialized))
  echo ""

  if kind in {lkAll, lkAoS}:
    printResult(bench("todo list AoS", iterations, proc(): string = serializeAoS(todos)))
  if kind in {lkAll, lkSoA}:
    printResult(bench("todo list SoA", iterations, proc(): string = serializeSoA(soa)))
  if kind in {lkAll, lkPrepared}:
    printResult(bench("todo list SoA prepared", iterations, proc(): string = serializePrepared(prepared)))
  if kind in {lkAll, lkMaterialized}:
    printResult(bench("todo list materialized rows", iterations, proc(): string = serializeMaterialized(materialized)))
