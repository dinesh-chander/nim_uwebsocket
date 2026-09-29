## Profile-focused benchmark: runs ONLY fastjson on canada.json
import std/[monotimes, os, times]
import ../../nim_fastjson

let fastJson = initFastJson()

type
  CanadaProperties = object
    name: string

  CanadaGeometry = object
    `type`: string
    coordinates: seq[seq[seq[float64]]]

  CanadaFeature = object
    `type`: string
    properties: CanadaProperties
    geometry: CanadaGeometry

  CanadaGeoJson = object
    `type`: string
    features: seq[CanadaFeature]

when isMainModule:
  let mode = if paramCount() > 0: paramStr(1) else: "serialize"
  let dataDir = if paramCount() > 1 and dirExists(paramStr(2)): paramStr(2)
                else: "benchmark/data"
  let json = readFile(dataDir / "canada.json")
  let data = fastJson.deserialize(json, CanadaGeoJson)

  echo "mode: ", mode, " | canada.json (", json.len, " bytes, ", data.features.len, " features)"

  let start = getMonoTime()
  var iterations = 0
  if mode == "serialize":
    while inNanoseconds(getMonoTime() - start) < 10_000_000_000'i64:
      discard fastJson.serialize(data)
      inc iterations
  elif mode == "deserialize":
    while inNanoseconds(getMonoTime() - start) < 10_000_000_000'i64:
      discard fastJson.deserialize(json, CanadaGeoJson)
      inc iterations
  else:
    echo "usage: bench_profile_canada [serialize|deserialize] [dataDir]"
    quit(1)

  let elapsed = getMonoTime() - start
  let seconds = inNanoseconds(elapsed).float / 1_000_000_000.0
  echo iterations, " iterations in ", seconds, "s"
  echo "  ", iterations.float / seconds, " ops/sec"
