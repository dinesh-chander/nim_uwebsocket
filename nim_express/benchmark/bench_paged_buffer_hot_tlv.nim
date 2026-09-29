import std/[os, strutils, times]

import nim_express/paged_buffer

proc benchPagedBuffer(iterations: int, pageSize: int): tuple[ms: float, checksum: int] =
  var buf = initPageBuffer(pageSize)
  let startTs = epochTime()
  for i in 0..<iterations:
    buf.add("k=")
    buf.addInt(i)
    buf.add('&')
  let payload = buf.takeStringAndClear()
  let endTs = epochTime()
  result.ms = (endTs - startTs) * 1000.0
  result.checksum = payload.len
  buf.release()

when isMainModule:
  var iterations = 500_000
  var pageSize = 256
  if paramCount() >= 1:
    iterations = parseInt(paramStr(1))
  if paramCount() >= 2:
    pageSize = parseInt(paramStr(2))
  if iterations <= 0:
    quit("iterations must be > 0", QuitFailure)
  if pageSize <= 0:
    quit("pageSize must be > 0", QuitFailure)

  discard benchPagedBuffer(10_000, pageSize)
  let result = benchPagedBuffer(iterations, pageSize)
  let opsPerSec =
    if result.ms <= 0.0: 0.0
    else: iterations.float * 1000.0 / result.ms

  echo "bench_paged_buffer_hot_tlv"
  echo "  iterations: ", iterations
  echo "  pageSize: ", pageSize
  echo "  elapsed_ms: ", formatFloat(result.ms, ffDecimal, 2)
  echo "  ops_per_sec: ", formatFloat(opsPerSec, ffDecimal, 0)
  echo "  checksum: ", result.checksum
