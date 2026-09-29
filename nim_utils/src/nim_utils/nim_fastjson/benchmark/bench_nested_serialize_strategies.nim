import std/[formatfloat, monotimes, os, strutils, times]
import std/private/digitsutils
import jsony

import ../../nim_fastjson

let fastJson = initFastJson()

template serialize(value: untyped): untyped =
  fastJson.serialize(value)

type
  Metric = object
    kind: string
    value: float64

  ChildNode = object
    id: int
    name: string
    tags: seq[string]
    metrics: seq[Metric]
    completed: bool

  NestedEnvelope = object
    version: int
    requestId: string
    children: seq[ChildNode]
    nextCursor: string

  PagedWriter = object
    pageSize: int
    pages: seq[string]
    current: string

  PreparedNested = object
    prefix: string
    children: seq[string]
    suffix: string

const
  ByteHighBits = 0x8080808080808080'u64
  ByteLowMask = 0x0101010101010101'u64
  ControlFloor = 0x2020202020202020'u64
  QuoteMask = 0x2222222222222222'u64
  SlashMask = 0x5c5c5c5c5c5c5c5c'u64
  HexDigits = "0123456789abcdef"

proc buildNested(childCount, tagCount, metricCount: int): NestedEnvelope =
  result.version = 3
  result.requestId = "req_" & $childCount & "_" & $tagCount & "_" & $metricCount
  result.nextCursor = "next_" & $childCount
  result.children = newSeq[ChildNode](childCount)
  for i in 0..<childCount:
    result.children[i].id = i + 1
    result.children[i].name = "child_" & $i
    result.children[i].completed = (i and 1) == 0
    result.children[i].tags = newSeq[string](tagCount)
    for tagIdx in 0..<tagCount:
      result.children[i].tags[tagIdx] = "tag_" & $tagIdx & "_" & $i
    result.children[i].metrics = newSeq[Metric](metricCount)
    for metricIdx in 0..<metricCount:
      result.children[i].metrics[metricIdx] = Metric(
        kind: "metric_" & $metricIdx,
        value: float64((i + 1) * (metricIdx + 3)) / 7.0
      )

proc bench(name: string, iterations: int, op: proc()) =
  let start = getMonoTime()
  for _ in 0..<iterations:
    op()
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let ops = float(iterations) / (float(elapsedNs) / 1_000_000_000.0)
  echo name, ": ", formatFloat(ops, ffDecimal, 2), " ops/s"

proc hasZeroByte(word: uint64): bool {.inline.} =
  ((word - ByteLowMask) and (not word) and ByteHighBits) != 0

proc hasUnsafeJsonBytes(value: string): bool =
  var idx = 0
  while idx + 8 <= value.len:
    var chunk: uint64
    copyMem(addr chunk, unsafeAddr value[idx], 8)
    if (chunk and ByteHighBits) != 0'u64:
      break
    if hasZeroByte(chunk xor QuoteMask) or hasZeroByte(chunk xor SlashMask):
      return true
    if ((chunk - ControlFloor) and (not chunk) and ByteHighBits) != 0'u64:
      return true
    idx += 8
  while idx < value.len:
    let c = value[idx]
    if c == '"' or c == '\\' or c < ' ':
      return true
    inc idx
  false

proc appendSpan(buf: var string, src: string, startIdx, spanLen: int) {.inline.} =
  if spanLen <= 0:
    return
  let base = buf.len
  buf.setLen(base + spanLen)
  copyMem(addr buf[base], unsafeAddr src[startIdx], spanLen)

proc appendEscaped(buf: var string, value: string) =
  if not hasUnsafeJsonBytes(value):
    buf.add('"')
    appendSpan(buf, value, 0, value.len)
    buf.add('"')
    return
  buf.add('"')
  var copyStart = 0
  for i, c in value:
    case c
    of '"':
      appendSpan(buf, value, copyStart, i - copyStart)
      buf.add("\\\"")
      copyStart = i + 1
    of '\\':
      appendSpan(buf, value, copyStart, i - copyStart)
      buf.add("\\\\")
      copyStart = i + 1
    of '\b':
      appendSpan(buf, value, copyStart, i - copyStart)
      buf.add("\\b")
      copyStart = i + 1
    of '\f':
      appendSpan(buf, value, copyStart, i - copyStart)
      buf.add("\\f")
      copyStart = i + 1
    of '\n':
      appendSpan(buf, value, copyStart, i - copyStart)
      buf.add("\\n")
      copyStart = i + 1
    of '\r':
      appendSpan(buf, value, copyStart, i - copyStart)
      buf.add("\\r")
      copyStart = i + 1
    of '\t':
      appendSpan(buf, value, copyStart, i - copyStart)
      buf.add("\\t")
      copyStart = i + 1
    else:
      if c < ' ':
        appendSpan(buf, value, copyStart, i - copyStart)
        buf.add("\\u00")
        buf.add(HexDigits[(ord(c) shr 4) and 0x0f])
        buf.add(HexDigits[ord(c) and 0x0f])
        copyStart = i + 1
  appendSpan(buf, value, copyStart, value.len - copyStart)
  buf.add('"')

proc ensureSpace(w: var PagedWriter, needed: int) =
  if w.current.len + needed <= w.pageSize:
    return
  w.pages.add(move w.current)
  w.current = newStringOfCap(max(w.pageSize, needed))

proc add(w: var PagedWriter, c: char) =
  w.ensureSpace(1)
  w.current.add(c)

proc add(w: var PagedWriter, s: string) =
  if s.len >= w.pageSize:
    if w.current.len > 0:
      w.pages.add(move w.current)
      w.current = newStringOfCap(w.pageSize)
    w.pages.add(s)
    return
  w.ensureSpace(s.len)
  w.current.add(s)

proc addInt(w: var PagedWriter, x: int) =
  w.ensureSpace(24)
  w.current.addInt(x)

proc addFloat(w: var PagedWriter, x: float64) =
  w.ensureSpace(32)
  w.current.addFloat(x)

proc addEscaped(w: var PagedWriter, s: string) =
  if not hasUnsafeJsonBytes(s):
    w.ensureSpace(s.len + 2)
    w.current.add('"')
    w.current.add(s)
    w.current.add('"')
    return
  var tmp = newStringOfCap(max(8, s.len + 2))
  appendEscaped(tmp, s)
  w.add(tmp)

proc finish(w: var PagedWriter): string =
  var total = w.current.len
  for page in w.pages:
    total += page.len
  result = newStringOfCap(total)
  for page in w.pages:
    result.add(page)
  result.add(w.current)

proc writeMetric(buf: var string, value: Metric) =
  buf.add("{\"kind\":")
  appendEscaped(buf, value.kind)
  buf.add(",\"value\":")
  buf.addFloat(value.value)
  buf.add('}')

proc writeMetric(w: var PagedWriter, value: Metric) =
  w.add("{\"kind\":")
  w.addEscaped(value.kind)
  w.add(",\"value\":")
  w.addFloat(value.value)
  w.add('}')

proc writeChild(buf: var string, value: ChildNode) =
  buf.add("{\"id\":")
  buf.addInt(value.id)
  buf.add(",\"name\":")
  appendEscaped(buf, value.name)
  buf.add(",\"tags\":[")
  var i = 0
  while i < value.tags.len:
    if i > 0:
      buf.add(',')
    appendEscaped(buf, value.tags[i])
    inc i
  buf.add("],\"metrics\":[")
  i = 0
  while i < value.metrics.len:
    if i > 0:
      buf.add(',')
    writeMetric(buf, value.metrics[i])
    inc i
  buf.add("],\"completed\":")
  if value.completed: buf.add("true") else: buf.add("false")
  buf.add('}')

proc writeChild(w: var PagedWriter, value: ChildNode) =
  w.add("{\"id\":")
  w.addInt(value.id)
  w.add(",\"name\":")
  w.addEscaped(value.name)
  w.add(",\"tags\":[")
  var i = 0
  while i < value.tags.len:
    if i > 0:
      w.add(',')
    w.addEscaped(value.tags[i])
    inc i
  w.add("],\"metrics\":[")
  i = 0
  while i < value.metrics.len:
    if i > 0:
      w.add(',')
    writeMetric(w, value.metrics[i])
    inc i
  w.add("],\"completed\":")
  if value.completed: w.add("true") else: w.add("false")
  w.add('}')

proc serializeSchemaSpecific(value: NestedEnvelope): string =
  result = newStringOfCap(max(256, value.children.len * 192))
  result.add("{\"version\":")
  result.addInt(value.version)
  result.add(",\"requestId\":")
  appendEscaped(result, value.requestId)
  result.add(",\"children\":[")
  var i = 0
  while i < value.children.len:
    if i > 0:
      result.add(',')
    writeChild(result, value.children[i])
    inc i
  result.add("],\"nextCursor\":")
  appendEscaped(result, value.nextCursor)
  result.add('}')

proc serializePaged(value: NestedEnvelope): string =
  var w = PagedWriter(pageSize: 4096, current: newStringOfCap(4096))
  w.add("{\"version\":")
  w.addInt(value.version)
  w.add(",\"requestId\":")
  w.addEscaped(value.requestId)
  w.add(",\"children\":[")
  var i = 0
  while i < value.children.len:
    if i > 0:
      w.add(',')
    writeChild(w, value.children[i])
    inc i
  w.add("],\"nextCursor\":")
  w.addEscaped(value.nextCursor)
  w.add('}')
  result = w.finish()

proc prepareNested(value: NestedEnvelope): PreparedNested =
  result.prefix = newStringOfCap(128)
  result.prefix.add("{\"version\":")
  result.prefix.addInt(value.version)
  result.prefix.add(",\"requestId\":")
  appendEscaped(result.prefix, value.requestId)
  result.prefix.add(",\"children\":[")
  result.children = newSeq[string](value.children.len)
  for i in 0..<value.children.len:
    result.children[i] = serializeSchemaSpecific(NestedEnvelope(
      version: 0,
      requestId: "",
      children: @[value.children[i]],
      nextCursor: ""
    ))
    result.children[i] = result.children[i][result.children[i].find('[') + 1 ..< result.children[i].rfind(']')]
  result.suffix = "],\"nextCursor\":"
  appendEscaped(result.suffix, value.nextCursor)
  result.suffix.add('}')

proc serializePrepared(value: PreparedNested): string =
  var total = value.prefix.len + value.suffix.len
  for child in value.children:
    total += child.len
  if value.children.len > 1:
    total += value.children.len - 1
  result = newStringOfCap(total)
  result.add(value.prefix)
  for i, child in value.children:
    if i > 0:
      result.add(',')
    result.add(child)
  result.add(value.suffix)

when isMainModule:
  let iterations =
    if paramCount() > 0: parseInt(paramStr(1))
    else: 10000
  let scenario =
    if paramCount() > 1: paramStr(2)
    else: "nested"

  let payload =
    if scenario == "large_nested": buildNested(64, 8, 6)
    else: buildNested(8, 4, 3)
  let prepared = prepareNested(payload)
  let jsonyPayload = jsony.toJson(payload)

  bench(scenario & " serialize jsony", iterations, proc() =
    discard jsony.toJson(payload)
  )
  bench(scenario & " serialize nim_fastjson", iterations, proc() =
    discard serialize(payload)
  )
  bench(scenario & " serialize schema_specific", iterations, proc() =
    discard serializeSchemaSpecific(payload)
  )
  bench(scenario & " serialize paged", iterations, proc() =
    discard serializePaged(payload)
  )
  bench(scenario & " serialize prepared", iterations, proc() =
    discard serializePrepared(prepared)
  )
  doAssert serialize(payload) == jsonyPayload
  doAssert serializeSchemaSpecific(payload) == jsonyPayload
  doAssert serializePaged(payload) == jsonyPayload
  doAssert serializePrepared(prepared) == jsonyPayload
