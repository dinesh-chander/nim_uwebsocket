## Profile-focused benchmark: runs ONLY fastjson serialize on twitter.json
## for 10 seconds so `sample` or Instruments can capture hotspots.
import std/[monotimes, os, times, options, tables]
import ../../nim_fastjson

let fastJson = initFastJson()

template serialize(value: untyped): untyped =
  fastJson.serialize(value)

template deserialize(json: untyped, T: typedesc): untyped =
  fastJson.deserialize(json, T)

# ── twitter.json types (same as bench_realworld) ──
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

when isMainModule:
  let mode = if paramCount() > 0: paramStr(1) else: "serialize"
  let dataDir = "benchmark/data"
  let json = readFile(dataDir / "twitter.json")
  let data = deserialize(json, TwitterResponse)

  echo "mode: ", mode, " | twitter.json (", json.len, " bytes, ", data.statuses.len, " tweets)"
  echo "running for 10 seconds..."

  let deadline = getMonoTime() + initDuration(seconds = 10)
  var count = 0

  if mode == "serialize":
    while getMonoTime() < deadline:
      for _ in 0..99:
        discard serialize(data)
      count += 100
  elif mode == "deserialize":
    while getMonoTime() < deadline:
      for _ in 0..99:
        discard deserialize(json, TwitterResponse)
      count += 100
  else:
    echo "usage: bench_profile_ser [serialize|deserialize]"
    quit(1)

  let elapsed = inNanoseconds(getMonoTime() - (deadline - initDuration(seconds = 10)))
  echo count, " iterations in ", float(elapsed) / 1e9, "s"
  echo "  ", float(count) / (float(elapsed) / 1e9), " ops/sec"
