import std/os

{.define: fastjsonIncludeOnly.}
include "bench_api_surface"

when isMainModule:
  if paramCount() < 2:
    quit "usage: normalize_cross_runtime_payloads <dataDir> <outDir>", 1

  let dataDir = paramStr(1)
  let outDir = paramStr(2)
  createDir(outDir)

  let twitterBase = fastJson.deserialize(loadJson(dataDir / "twitter.json"), TwitterResponse)
  let citmBase = fastJson.deserialize(loadJson(dataDir / "citm_catalog.json"), CitmCatalog)
  let canadaBase = fastJson.deserialize(loadJson(dataDir / "canada.json"), CanadaGeoJson)
  let historicalBase = fastJson.deserialize(loadJson(dataDir / "historical_events.json"), seq[HistoricalEvent])

  writeFile(outDir / "twitter.json", fastJson.serialize(twitterBase))
  writeFile(outDir / "citm_catalog.json", fastJson.serialize(citmBase))
  writeFile(outDir / "canada.json", fastJson.serialize(canadaBase))
  writeFile(outDir / "historical_events.json", fastJson.serialize(historicalBase))
