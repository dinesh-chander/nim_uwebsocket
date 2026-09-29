import std/[monotimes, os, strutils, times]
import jsony

import ../../nim_fastjson

let fastJson = initFastJson()

template serialize(value: untyped): untyped =
  fastJson.serialize(value)

template deserialize(json: untyped, T: typedesc): untyped =
  fastJson.deserialize(json, T)

type
  NumericPoint = object
    x: float64
    y: float64
    z: float64
    weight: float64

  NumericEnvelope = object
    points: seq[NumericPoint]
    bias: float64
    scale: float64
    total: float64

proc buildNumeric(count: int): NumericEnvelope =
  result.bias = 1.25
  result.scale = 3.75
  result.total = 0.0
  result.points = newSeq[NumericPoint](count)
  for i in 0..<count:
    let base = float64(i + 1)
    result.points[i] = NumericPoint(
      x: base / 7.0,
      y: base * 1.125,
      z: (base + 3.0) / 11.0,
      weight: (base * 13.0) / 17.0
    )
    result.total += result.points[i].x + result.points[i].y + result.points[i].z + result.points[i].weight

proc bench(name: string, iterations: int, op: proc()) =
  let start = getMonoTime()
  for _ in 0..<iterations:
    op()
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let ops = float(iterations) / (float(elapsedNs) / 1_000_000_000.0)
  echo name, ": ", formatFloat(ops, ffDecimal, 2), " ops/s"

when isMainModule:
  let iterations =
    if paramCount() > 0: parseInt(paramStr(1))
    else: 10000
  let env = buildNumeric(128)
  let payload = jsony.toJson(env)
  echo "numeric bytes=", payload.len
  bench("serialize jsony numeric", iterations, proc() =
    discard jsony.toJson(env)
  )
  bench("serialize nim_fastjson numeric", iterations, proc() =
    discard serialize(env)
  )
  bench("deserialize jsony numeric", iterations, proc() =
    discard jsony.fromJson(payload, NumericEnvelope)
  )
  bench("deserialize nim_fastjson numeric", iterations, proc() =
    discard deserialize(payload, NumericEnvelope)
  )
