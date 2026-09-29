import std/[os, strformat, strutils, times]

import ../src/nim_express/simdjson_utils

type
  BenchResult = object
    iterations: int
    elapsedMs: float
    checksum: int

proc msBetween(startedAt, endedAt: float): float {.inline.} =
  (endedAt - startedAt) * 1000.0

proc opsPerSec(iterations: int, elapsedMs: float): float {.inline.} =
  if elapsedMs <= 0.0:
    return 0.0
  iterations.float * 1000.0 / elapsedMs

proc benchTodoPayload(payload: string, iterations: int): BenchResult =
  var checksum = 0
  let startedAt = epochTime()
  for _ in 0 ..< iterations:
    let parsed = parseTodoMutationPayloadFast(payload)
    if parsed.ok:
      if parsed.payload.hasTitle:
        inc checksum, parsed.payload.title.len
      if parsed.payload.hasCompleted and parsed.payload.completed:
        inc checksum
  let endedAt = epochTime()
  BenchResult(
    iterations: iterations,
    elapsedMs: msBetween(startedAt, endedAt),
    checksum: checksum
  )

when isMainModule:
  var iterations = 1_000_000
  if paramCount() >= 1:
    iterations = parseInt(paramStr(1))
  if iterations <= 0:
    quit("iterations must be > 0", QuitFailure)

  let payload = """{"title":"ship wrapper","completed":true,"meta":{"source":"bench","tags":["nim","simdjson","todo"],"count":3}}"""

  echo &"Benchmark iterations={iterations}"
  echo "Warming up..."
  discard benchTodoPayload(payload, min(iterations, 20_000))
  echo ""

  let result = benchTodoPayload(payload, iterations)
  echo "todo payload parser"
  echo "  iterations: ", result.iterations
  echo "  elapsed:    ", formatFloat(result.elapsedMs, ffDecimal, 2), " ms"
  echo "  throughput: ", formatFloat(opsPerSec(result.iterations, result.elapsedMs), ffDecimal, 0), " ops/s"
  echo "  checksum:   ", result.checksum
