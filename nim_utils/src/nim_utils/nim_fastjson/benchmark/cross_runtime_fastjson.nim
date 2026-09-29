import std/[json, os]

{.define: fastjsonIncludeOnly.}
include "bench_api_surface"

const WarmupPasses = 10

proc benchSecondPass(iterations: int; op: proc()): (float, float) =
  for _ in 0..<WarmupPasses:
    discard bench(iterations, op)
  bench(iterations, op)

proc benchOne[T](dataset: string; value: T) =
  let payload = jsony.toJson(value)
  if payload.len > MaxScenarioBytes:
    return
  let iterations = chooseIterations(payload.len)
  let typedValue = fastJson.deserialize(payload, T)
  let (deserOps, deserNs) = benchSecondPass(iterations, proc() = discard fastJson.deserialize(payload, T))
  let (serOps, serNs) = benchSecondPass(iterations, proc() = discard fastJson.serialize(typedValue))
  echo $(%*{
    "dataset": dataset,
    "payload_bytes": payload.len,
    "iterations": iterations,
    "deserialize_ops": deserOps,
    "deserialize_ns": deserNs,
    "serialize_ops": serOps,
    "serialize_ns": serNs
  })

when isMainModule:
  let dataDir =
    if paramCount() > 0 and dirExists(paramStr(1)): paramStr(1)
    else: "benchmark/data"

  let twitterBase = fastJson.deserialize(loadJson(dataDir / "twitter.json"), TwitterResponse)
  let citmBase = fastJson.deserialize(loadJson(dataDir / "citm_catalog.json"), CitmCatalog)
  let canadaBase = fastJson.deserialize(loadJson(dataDir / "canada.json"), CanadaGeoJson)
  let historicalBase = fastJson.deserialize(loadJson(dataDir / "historical_events.json"), seq[HistoricalEvent])

  benchOne("twitter", twitterBase)
  benchOne("citm", citmBase)
  benchOne("canada", canadaBase)
  benchOne("historical", historicalBase)
