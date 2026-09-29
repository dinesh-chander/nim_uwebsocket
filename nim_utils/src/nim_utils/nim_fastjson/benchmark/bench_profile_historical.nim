## Profile-focused benchmark: runs ONLY fastjson on historical_events.json
## for 10 seconds so `sample` or Instruments can capture hotspots.
import std/[monotimes, os, times]
import ../../nim_fastjson

let fastJson = initFastJson()

type
  HistoricalEvent = object
    date: string
    description: string
    lang: string
    category1: string
    category2: string
    granularity: string

when isMainModule:
  let mode = if paramCount() > 0: paramStr(1) else: "deserialize"
  let dataDir = "benchmark/data"
  let json = readFile(dataDir / "historical_events.json")
  let data = fastJson.deserialize(json, seq[HistoricalEvent])

  echo "mode: ", mode, " | historical_events.json (", json.len, " bytes, ", data.len, " events)"
  echo "running for 10 seconds..."

  let deadline = getMonoTime() + initDuration(seconds = 10)
  var count = 0

  if mode == "serialize":
    while getMonoTime() < deadline:
      for _ in 0..99:
        discard fastJson.serialize(data)
      count += 100
  elif mode == "deserialize":
    while getMonoTime() < deadline:
      for _ in 0..9:
        discard fastJson.deserialize(json, seq[HistoricalEvent])
      count += 10
  else:
    echo "usage: bench_profile_historical [serialize|deserialize]"
    quit(1)

  let elapsed = inNanoseconds(getMonoTime() - (deadline - initDuration(seconds = 10)))
  echo count, " iterations in ", float(elapsed) / 1e9, "s"
  echo "  ", float(count) / (float(elapsed) / 1e9), " ops/sec"
