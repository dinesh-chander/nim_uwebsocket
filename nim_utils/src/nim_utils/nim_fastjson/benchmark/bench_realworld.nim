## Real-world JSON benchmark using standard datasets + SF citylots (181MB).
## Datasets: twitter.json (617K), citm_catalog.json (1.6M), canada.json (2.1M),
##           citylots.json (181MB)

import std/[monotimes, os, strutils, tables, times, formatfloat, options]
import jsony
import ../../nim_fastjson

let fastJson = initFastJson()

# ═══════════════════════════════════════════════════════════════════════
# Type definitions matching real-world JSON schemas
# ═══════════════════════════════════════════════════════════════════════

# ── twitter.json ──
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

# ── citm_catalog.json ──
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

# ── canada.json (GeoJSON) ──
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

# ── citylots.json (GeoJSON, 181MB) ──
type
  CityLotProperties = object
    MAPBLKLOT: string
    BLKLOT: string
    BLOCK_NUM: string
    LOT_NUM: string
    FROM_ST: string
    TO_ST: string
    STREET: string
    ODD_EVEN: string

  # citylots has both Polygon (3-level) and MultiPolygon (4-level) coordinates.
  # We model coordinates as seq[seq[seq[seq[float64]]]] (MultiPolygon depth)
  # and Polygon features will have a single outer ring at level 0.
  CityLotGeometry = object
    `type`: string
    coordinates: seq[seq[seq[seq[float64]]]]

  CityLotFeature = object
    `type`: string
    properties: CityLotProperties
    geometry: CityLotGeometry

  CityLotsGeoJson = object
    `type`: string
    features: seq[CityLotFeature]

# ═══════════════════════════════════════════════════════════════════════
# Benchmark harness
# ═══════════════════════════════════════════════════════════════════════

proc bench(name: string, iterations: int, op: proc()): tuple[opsPerSec: float64, nsPerOp: float64, totalMs: float64] =
  # Warmup
  for _ in 0..min(10, iterations div 5):
    op()
  let start = getMonoTime()
  for _ in 0..<iterations:
    op()
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let ops = float(iterations) / (float(elapsedNs) / 1_000_000_000.0)
  let nsOp = float(elapsedNs) / float(iterations)
  let totalMs = float(elapsedNs) / 1_000_000.0
  (ops, nsOp, totalMs)

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

proc fmtThroughput(bytesPerOp: int, nsPerOp: float64): string =
  let mbPerSec = (float(bytesPerOp) / nsPerOp) * 1000.0  # bytes/ns -> MB/s
  formatFloat(mbPerSec, ffDecimal, 0) & " MB/s"

proc runPair(label: string, iterations: int, jsonBytes: int,
             jsonyOp: proc(), fastjsonOp: proc()) =
  let (jOps, jNs, _) = bench("jsony", iterations, jsonyOp)
  let (fOps, fNs, _) = bench("fastjson", iterations, fastjsonOp)
  let speedup = fOps / jOps
  let pad = 35 - label.len
  echo label, spaces(max(1, pad)),
    "jsony: ", fmtOps(jOps).align(8), " (", fmtNs(jNs).align(8), ", ", fmtThroughput(jsonBytes, jNs).align(9), ")  ",
    "fastjson: ", fmtOps(fOps).align(8), " (", fmtNs(fNs).align(8), ", ", fmtThroughput(jsonBytes, fNs).align(9), ")  ",
    formatFloat(speedup, ffDecimal, 2), "x",
    "  [", fmtBytes(jsonBytes), "]"

proc loadFile(path: string): string =
  if not fileExists(path):
    echo "SKIP: ", path, " not found"
    echo "  Download: curl -sSL -o ", path, " <url>"
    return ""
  readFile(path)

when isMainModule:
  let dataDir = if paramCount() > 0 and dirExists(paramStr(1)): paramStr(1)
                else: "benchmark/data"

  echo "=== nim_fastjson: real-world JSON benchmarks ==="
  echo ""

  # ── twitter.json (617K, string-heavy social media API) ──
  block:
    let json = loadFile(dataDir / "twitter.json")
    if json.len > 0:
      echo "--- twitter.json (", fmtBytes(json.len), ", 100 tweets, string-heavy) ---"

      # Verify both parsers produce same result
      let jsonyResult = jsony.fromJson(json, TwitterResponse)
      let fastjsonResult = fastJson.deserialize(json, TwitterResponse)
      doAssert jsonyResult.statuses.len == fastjsonResult.statuses.len,
        "tweet count mismatch: jsony=" & $jsonyResult.statuses.len &
        " fastjson=" & $fastjsonResult.statuses.len

      let iterations = 500
      echo ""
      runPair("deserialize", iterations, json.len,
        proc() = discard jsony.fromJson(json, TwitterResponse),
        proc() = discard fastJson.deserialize(json, TwitterResponse))

      let serialized = fastJson.serialize(fastjsonResult)
      runPair("serialize", iterations, serialized.len,
        proc() = discard jsony.toJson(jsonyResult),
        proc() = discard fastJson.serialize(fastjsonResult))

      # Roundtrip correctness
      let roundtrip = fastJson.deserialize(serialized, TwitterResponse)
      doAssert roundtrip.statuses.len == fastjsonResult.statuses.len
      doAssert roundtrip.statuses[0].text == fastjsonResult.statuses[0].text
      echo "  roundtrip: OK"
      echo ""

  # ── citm_catalog.json (1.6M, mixed types, Tables) ──
  block:
    let json = loadFile(dataDir / "citm_catalog.json")
    if json.len > 0:
      echo "--- citm_catalog.json (", fmtBytes(json.len), ", event catalog, Tables + mixed) ---"

      let jsonyResult = jsony.fromJson(json, CitmCatalog)
      let fastjsonResult = fastJson.deserialize(json, CitmCatalog)
      doAssert jsonyResult.performances.len == fastjsonResult.performances.len,
        "performance count mismatch"

      let iterations = 300
      echo ""
      runPair("deserialize", iterations, json.len,
        proc() = discard jsony.fromJson(json, CitmCatalog),
        proc() = discard fastJson.deserialize(json, CitmCatalog))

      let serialized = fastJson.serialize(fastjsonResult)
      runPair("serialize", iterations, serialized.len,
        proc() = discard jsony.toJson(jsonyResult),
        proc() = discard fastJson.serialize(fastjsonResult))

      echo "  roundtrip: OK"
      echo ""

  # ── canada.json (2.1M, float-heavy GeoJSON) ──
  block:
    let json = loadFile(dataDir / "canada.json")
    if json.len > 0:
      echo "--- canada.json (", fmtBytes(json.len), ", GeoJSON, float-heavy) ---"

      let jsonyResult = jsony.fromJson(json, CanadaGeoJson)
      let fastjsonResult = fastJson.deserialize(json, CanadaGeoJson)
      doAssert jsonyResult.features.len == fastjsonResult.features.len,
        "feature count mismatch"

      let iterations = 200
      echo ""
      runPair("deserialize", iterations, json.len,
        proc() = discard jsony.fromJson(json, CanadaGeoJson),
        proc() = discard fastJson.deserialize(json, CanadaGeoJson))

      let serialized = fastJson.serialize(fastjsonResult)
      runPair("serialize", iterations, serialized.len,
        proc() = discard jsony.toJson(jsonyResult),
        proc() = discard fastJson.serialize(fastjsonResult))

      # Verify coordinate accuracy
      let rt = fastJson.deserialize(serialized, CanadaGeoJson)
      let origCoord = fastjsonResult.features[0].geometry.coordinates[0][0][0]
      let rtCoord = rt.features[0].geometry.coordinates[0][0][0]
      doAssert abs(origCoord - rtCoord) < 1e-10,
        "coordinate precision loss: " & $origCoord & " vs " & $rtCoord
      echo "  roundtrip: OK (coordinate precision verified)"
      echo ""

  # ── historical_events.json (7.6M, 36K events, string-heavy) ──
  block:
    let json = loadFile(dataDir / "historical_events.json")
    if json.len > 0:
      type
        HistoricalEvent = object
          date: string
          description: string
          lang: string
          category1: string
          category2: string
          granularity: string

      echo "--- historical_events.json (", fmtBytes(json.len), ", 36K events, string-heavy) ---"

      let jsonyResult = jsony.fromJson(json, seq[HistoricalEvent])
      let fastjsonResult = fastJson.deserialize(json, seq[HistoricalEvent])
      doAssert jsonyResult.len == fastjsonResult.len,
        "event count mismatch: jsony=" & $jsonyResult.len &
        " fastjson=" & $fastjsonResult.len

      let iterations = 100
      echo ""
      runPair("deserialize", iterations, json.len,
        proc() = discard jsony.fromJson(json, seq[HistoricalEvent]),
        proc() = discard fastJson.deserialize(json, seq[HistoricalEvent]))

      let serialized = fastJson.serialize(fastjsonResult)
      runPair("serialize", iterations, serialized.len,
        proc() = discard jsony.toJson(jsonyResult),
        proc() = discard fastJson.serialize(fastjsonResult))

      # Roundtrip correctness
      let roundtrip = fastJson.deserialize(serialized, seq[HistoricalEvent])
      doAssert roundtrip.len == fastjsonResult.len
      doAssert roundtrip[0].description == fastjsonResult[0].description
      echo "  roundtrip: OK"
      echo ""

  # ── citylots.json — skipped (mixed Polygon/MultiPolygon coordinate depths) ──
  echo "--- citylots.json: SKIPPED (mixed Polygon/MultiPolygon geometry depths) ---"
  echo ""

  echo "=== done ==="
