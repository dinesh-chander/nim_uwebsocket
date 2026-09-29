import std/[formatfloat, monotimes, options, os, streams, strutils, tables, times]
import jsony

import ../../nim_fastjson

let fastJson = initFastJson()

const MaxScenarioBytes = 64 * 1024 * 1024

type
  TweetMetadata = object
    result_type: string
    iso_language_code: string

  TweetUrl = object
    url: string
    expanded_url: string
    display_url: string
    indices: seq[int]

  TweetUserEntities = object
    description: TweetUrlContainer

  TweetUrlContainer = object
    urls: seq[TweetUrl]

  TweetHashtag = object
    text: string
    indices: seq[int]

  TweetUserMention = object
    screen_name: string
    name: string
    id: int
    id_str: string
    indices: seq[int]

  TweetEntities = object
    hashtags: seq[TweetHashtag]
    urls: seq[TweetUrl]
    user_mentions: seq[TweetUserMention]

  TweetUser = object
    id: int
    id_str: string
    name: string
    screen_name: string
    location: string
    description: string
    protected: bool
    followers_count: int
    friends_count: int
    listed_count: int
    created_at: string
    favourites_count: int
    geo_enabled: bool
    verified: bool
    statuses_count: int
    lang: string
    contributors_enabled: bool
    is_translator: bool
    is_translation_enabled: bool
    profile_background_color: string
    profile_background_image_url: string
    profile_background_image_url_https: string
    profile_background_tile: bool
    profile_image_url: string
    profile_image_url_https: string
    profile_link_color: string
    profile_sidebar_border_color: string
    profile_sidebar_fill_color: string
    profile_text_color: string
    profile_use_background_image: bool
    default_profile: bool
    default_profile_image: bool
    entities: TweetUserEntities

  Tweet = object
    metadata: TweetMetadata
    created_at: string
    id: int
    id_str: string
    text: string
    source: string
    truncated: bool
    in_reply_to_status_id_str: string
    in_reply_to_user_id_str: string
    in_reply_to_screen_name: string
    user: TweetUser
    retweet_count: int
    favorite_count: int
    entities: TweetEntities
    favorited: bool
    retweeted: bool
    lang: string

  SearchMetadata = object
    completed_in: float64
    max_id: int
    max_id_str: string
    next_results: string
    query: string
    refresh_url: string
    count: int
    since_id: int
    since_id_str: string

  TwitterResponse = object
    statuses: seq[Tweet]
    search_metadata: SearchMetadata

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

  HistoricalEvent = object
    date: string
    description: string
    lang: string
    category1: string
    category2: string
    granularity: string

proc fmtOps(ops: float64): string =
  if ops >= 1_000_000:
    formatFloat(ops / 1_000_000.0, ffDecimal, 2) & "M"
  elif ops >= 1_000:
    formatFloat(ops / 1_000.0, ffDecimal, 1) & "K"
  else:
    formatFloat(ops, ffDecimal, 1)

proc fmtNs(ns: float64): string =
  if ns >= 1_000_000:
    formatFloat(ns / 1_000_000.0, ffDecimal, 2) & "ms"
  elif ns >= 1_000:
    formatFloat(ns / 1_000.0, ffDecimal, 1) & "us"
  else:
    formatFloat(ns, ffDecimal, 0) & "ns"

proc fmtBytes(b: int): string =
  if b >= 1_048_576:
    formatFloat(float(b) / 1_048_576.0, ffDecimal, 1) & "MB"
  elif b >= 1024:
    formatFloat(float(b) / 1024.0, ffDecimal, 1) & "KB"
  else:
    $b & "B"

proc toBytes(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for i, ch in value:
    result[i] = byte(ord(ch))

proc repeatSeqToLen[T](items: seq[T]; size: int): seq[T] =
  if items.len == 0 or size <= 0:
    return @[]
  result = newSeq[T](size)
  for i in 0..<size:
    result[i] = items[i mod items.len]

proc scaledTwitter(base: TwitterResponse; size: int): TwitterResponse =
  result = base
  result.statuses = repeatSeqToLen(base.statuses, size)
  result.search_metadata.count = size

proc scaledCitm(base: CitmCatalog; size: int): CitmCatalog =
  result = base
  result.performances = repeatSeqToLen(base.performances, size)

proc scaledCanada(base: CanadaGeoJson; size: int): CanadaGeoJson =
  result = base
  result.features = repeatSeqToLen(base.features, size)

proc scaledHistorical(base: seq[HistoricalEvent]; size: int): seq[HistoricalEvent] =
  repeatSeqToLen(base, size)

proc bench(iterations: int; op: proc()) : tuple[opsPerSec: float64, nsPerOp: float64] =
  for _ in 0..<min(iterations, 5):
    op()
  let started = getMonoTime()
  for _ in 0..<iterations:
    op()
  let elapsedNs = inNanoseconds(getMonoTime() - started)
  (float(iterations) / (float(elapsedNs) / 1_000_000_000.0), float(elapsedNs) / float(iterations))

proc chooseIterations(payloadBytes: int): int =
  if payloadBytes < 64 * 1024:
    300
  elif payloadBytes < 512 * 1024:
    120
  elif payloadBytes < 2 * 1024 * 1024:
    40
  else:
    12

proc printPair(label: string; iterations: int; jsonyOp, fastOp: proc()) =
  let (jOps, jNs) = bench(iterations, jsonyOp)
  let (fOps, fNs) = bench(iterations, fastOp)
  echo "  ", label.alignLeft(20),
    " jsony=", fmtOps(jOps).align(8), " (", fmtNs(jNs).align(8), ")",
    "  fastjson=", fmtOps(fOps).align(8), " (", fmtNs(fNs).align(8), ")",
    "  ", formatFloat(fOps / jOps, ffDecimal, 2), "x"

proc runScenario[T](dataset: string; size: int; value: T) =
  let payload = jsony.toJson(value)
  if payload.len > MaxScenarioBytes:
    echo ""
    echo dataset, " size=", size, " payload=", fmtBytes(payload.len), " skipped (exceeds ", fmtBytes(MaxScenarioBytes), ")"
    return
  let payloadBytes = toBytes(payload)
  let iterations = chooseIterations(payload.len)
  echo ""
  echo dataset, " size=", size, " payload=", fmtBytes(payload.len), " iterations=", iterations

  printPair("serialize", iterations,
    proc() = discard jsony.toJson(value),
    proc() = discard fastJson.serialize(value))

  printPair("serializeToBytes", iterations,
    proc() = discard toBytes(jsony.toJson(value)),
    proc() = discard fastJson.serializeToBytes(value))

  printPair("serializeToStream", iterations,
    proc() =
      let stream = newStringStream()
      stream.write(jsony.toJson(value))
      discard stream.data
      stream.close(),
    proc() =
      let stream = newStringStream()
      fastJson.serializeToStream(stream, value)
      discard stream.data
      stream.close())

  printPair("deserialize(string)", iterations,
    proc() = discard jsony.fromJson(payload, T),
    proc() = discard fastJson.deserialize(payload, T))

  printPair("deserialize(bytes)", iterations,
    proc() =
      var text = newString(payloadBytes.len)
      for i, b in payloadBytes:
        text[i] = char(b)
      discard jsony.fromJson(text, T),
    proc() = discard fastJson.deserialize(payloadBytes, T))

  printPair("deserialize(stream)", iterations,
    proc() =
      let stream = newStringStream(payload)
      let text = stream.readAll()
      stream.close()
      discard jsony.fromJson(text, T),
    proc() =
      let stream = newStringStream(payload)
      discard fastJson.deserialize(stream, T)
      stream.close())

  printPair("isValidJson(string)", iterations,
    proc() = discard jsony.fromJson(payload, T),
    proc() = doAssert fastJson.isValidJson(payload))

  printPair("isValidJson(bytes)", iterations,
    proc() =
      var text = newString(payloadBytes.len)
      for i, b in payloadBytes:
        text[i] = char(b)
      discard jsony.fromJson(text, T),
    proc() = doAssert fastJson.isValidJson(payloadBytes))

  printPair("isValidJson(stream)", iterations,
    proc() =
      let stream = newStringStream(payload)
      let text = stream.readAll()
      stream.close()
      discard jsony.fromJson(text, T),
    proc() =
      let stream = newStringStream(payload)
      doAssert fastJson.isValidJson(stream)
      stream.close())

  printPair("serializeToStream empty", iterations,
    proc() =
      let stream = newStringStream()
      stream.write(jsony.toJson(value))
      discard stream.data
      stream.close(),
    proc() =
      let stream = newStringStream()
      fastJson.serializeToStream(stream, value)
      discard stream.data
      stream.close())

proc loadJson(path: string): string =
  if not fileExists(path):
    raise newException(IOError, "missing benchmark input: " & path)
  readFile(path)

when isMainModule and not defined(fastjsonIncludeOnly):
  let dataDir =
    if paramCount() > 0 and dirExists(paramStr(1)): paramStr(1)
    else: "benchmark/data"

  let twitterBase = fastJson.deserialize(loadJson(dataDir / "twitter.json"), TwitterResponse)
  let citmBase = fastJson.deserialize(loadJson(dataDir / "citm_catalog.json"), CitmCatalog)
  let canadaBase = fastJson.deserialize(loadJson(dataDir / "canada.json"), CanadaGeoJson)
  let historicalBase = fastJson.deserialize(loadJson(dataDir / "historical_events.json"), seq[HistoricalEvent])

  echo "=== fastjson API surface vs jsony ==="
  echo "methods: serialize, serializeToBytes, serializeToStream, deserialize(string), deserialize(bytes), deserialize(stream)"
  echo "sizes: 10, 100, 1000"

  for size in [10, 100, 1000]:
    runScenario("twitter", size, scaledTwitter(twitterBase, size))
    runScenario("citm", size, scaledCitm(citmBase, size))
    runScenario("canada", size, scaledCanada(canadaBase, size))
    runScenario("historical", size, scaledHistorical(historicalBase, size))
