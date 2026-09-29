## Profile-focused benchmark: runs ONLY fastjson on citm_catalog.json
import std/[monotimes, options, os, tables, times]
import ../../nim_fastjson

let fastJson = initFastJson()

type
  CitmPrice = object
    amount: int
    audienceSubCategoryId: int
    seatCategoryId: int

  CitmArea = object
    areaId: int
    blockIds: seq[int]

  CitmSeatCategory = object
    areas: seq[CitmArea]
    seatCategoryId: int

  CitmPerformance = object
    eventId: int
    id: int
    name: Option[string]
    prices: seq[CitmPrice]
    seatCategories: seq[CitmSeatCategory]
    start: int
    venueCode: string

  CitmEvent = object
    id: int
    name: string
    subTopicIds: seq[int]
    topicIds: seq[int]

  CitmCatalog = object
    areaNames: Table[string, string]
    audienceSubCategoryNames: Table[string, string]
    events: Table[string, CitmEvent]
    performances: seq[CitmPerformance]
    seatCategoryNames: Table[string, string]
    subTopicNames: Table[string, string]
    topicNames: Table[string, string]
    topicSubTopics: Table[string, seq[int]]
    venueNames: Table[string, string]

when isMainModule:
  let mode = if paramCount() > 0: paramStr(1) else: "serialize"
  let dataDir = if paramCount() > 1 and dirExists(paramStr(2)): paramStr(2)
                else: "benchmark/data"
  let json = readFile(dataDir / "citm_catalog.json")
  let data = fastJson.deserialize(json, CitmCatalog)

  echo "mode: ", mode, " | citm_catalog.json (", json.len, " bytes, ", data.performances.len, " performances)"

  let start = getMonoTime()
  var iterations = 0
  if mode == "serialize":
    while inNanoseconds(getMonoTime() - start) < 10_000_000_000'i64:
      discard fastJson.serialize(data)
      inc iterations
  elif mode == "deserialize":
    while inNanoseconds(getMonoTime() - start) < 10_000_000_000'i64:
      discard fastJson.deserialize(json, CitmCatalog)
      inc iterations
  else:
    echo "usage: bench_profile_citm [serialize|deserialize] [dataDir]"
    quit(1)

  let elapsed = getMonoTime() - start
  let seconds = inNanoseconds(elapsed).float / 1_000_000_000.0
  echo iterations, " iterations in ", seconds, "s"
  echo "  ", iterations.float / seconds, " ops/sec"
