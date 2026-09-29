import std/[monotimes, os, strutils, times, formatfloat]
import jsony

import ../../nim_fastjson

let fastJson = initFastJson()

template serialize(value: untyped): untyped =
  fastJson.serialize(value)

template deserialize(json: untyped, T: typedesc): untyped =
  fastJson.deserialize(json, T)

# === Type definitions ===

# 1. Int-heavy: objects dominated by integer fields
type
  Metrics = object
    requests: int
    errors: int
    latencyP50: int
    latencyP95: int
    latencyP99: int
    bytesIn: int
    bytesOut: int
    connections: int

  MetricsReport = object
    items: seq[Metrics]

# 2. String-heavy: objects with many short strings
type
  UserProfile = object
    firstName: string
    lastName: string
    email: string
    city: string
    state: string
    country: string
    role: string
    team: string

  UserDirectory = object
    users: seq[UserProfile]

# 3. Float-heavy: numeric data
type
  PricePoint = object
    open: float64
    high: float64
    low: float64
    close: float64
    volume: float64
    vwap: float64

  TimeSeries = object
    points: seq[PricePoint]

# 4. Mixed: realistic API response
type
  Todo = object
    id: int
    title: string
    completed: bool

  Envelope = object
    todos: seq[Todo]
    nextCursor: string

# 5. Flat single object (no seq)
type
  Config = object
    host: string
    port: int
    debug: bool
    maxRetries: int
    timeout: float64
    region: string

# 6. Long strings: objects with larger text content
type
  Article = object
    id: int
    title: string
    body: string
    author: string

  ArticleFeed = object
    articles: seq[Article]

# 7. Nested objects
type
  Address = object
    street: string
    city: string
    zip: string

  Person = object
    name: string
    age: int
    address: Address

  PeopleList = object
    people: seq[Person]

# 8. Primitive arrays
type
  IntArray = object
    values: seq[int]

  StringArray = object
    values: seq[string]

# === Data generators ===

proc sampleMetrics(count: int): MetricsReport =
  result.items = newSeq[Metrics](count)
  for i in 0..<count:
    result.items[i] = Metrics(
      requests: 10000 + i * 137,
      errors: i mod 50,
      latencyP50: 5 + i mod 20,
      latencyP95: 25 + i mod 100,
      latencyP99: 100 + i mod 500,
      bytesIn: 1024 * (i + 1),
      bytesOut: 2048 * (i + 1),
      connections: 50 + i mod 200
    )

proc sampleUsers(count: int): UserDirectory =
  result.users = newSeq[UserProfile](count)
  for i in 0..<count:
    let s = $i
    result.users[i] = UserProfile(
      firstName: "Alice" & s,
      lastName: "Smith" & s,
      email: "alice" & s & "@example.com",
      city: "Portland",
      state: "OR",
      country: "US",
      role: "engineer",
      team: "platform"
    )

proc samplePrices(count: int): TimeSeries =
  result.points = newSeq[PricePoint](count)
  for i in 0..<count:
    let base = 100.0 + float64(i) * 0.37
    result.points[i] = PricePoint(
      open: base,
      high: base + 2.15,
      low: base - 1.83,
      close: base + 0.42,
      volume: 1_000_000.0 + float64(i) * 12345.67,
      vwap: base + 0.21
    )

proc sampleTodos(count: int): Envelope =
  result.nextCursor = "cursor_" & $count
  result.todos = newSeq[Todo](count)
  for i in 0..<count:
    result.todos[i] = Todo(
      id: i + 1,
      title: "todo_" & $i,
      completed: (i and 1) == 0
    )

proc sampleArticles(count: int): ArticleFeed =
  let loremBody = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " &
    "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. " &
    "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris."
  result.articles = newSeq[Article](count)
  for i in 0..<count:
    result.articles[i] = Article(
      id: i + 1,
      title: "Article number " & $i & " about interesting things",
      body: loremBody,
      author: "Author " & $i
    )

proc samplePeople(count: int): PeopleList =
  result.people = newSeq[Person](count)
  for i in 0..<count:
    result.people[i] = Person(
      name: "Person " & $i,
      age: 20 + (i mod 50),
      address: Address(
        street: $((i + 1) * 100) & " Main St",
        city: "Springfield",
        zip: "0" & $(10000 + i)
      )
    )

proc sampleIntArray(count: int): IntArray =
  result.values = newSeq[int](count)
  for i in 0..<count:
    result.values[i] = i * 137 + 42

proc sampleStringArray(count: int): StringArray =
  result.values = newSeq[string](count)
  for i in 0..<count:
    result.values[i] = "item_" & $i

# === Benchmark harness ===

proc bench(name: string, iterations: int, op: proc()): tuple[opsPerSec: float64, nsPerOp: float64] =
  # Warmup
  for _ in 0..min(100, iterations div 10):
    op()
  let start = getMonoTime()
  for _ in 0..<iterations:
    op()
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let ops = float(iterations) / (float(elapsedNs) / 1_000_000_000.0)
  let nsOp = float(elapsedNs) / float(iterations)
  (ops, nsOp)

proc fmtOps(ops: float64): string =
  if ops >= 1_000_000:
    formatFloat(ops / 1_000_000.0, ffDecimal, 2) & "M"
  elif ops >= 1_000:
    formatFloat(ops / 1_000.0, ffDecimal, 1) & "K"
  else:
    formatFloat(ops, ffDecimal, 0)

proc fmtNs(ns: float64): string =
  if ns >= 1_000_000:
    formatFloat(ns / 1_000_000.0, ffDecimal, 1) & "ms"
  elif ns >= 1_000:
    formatFloat(ns / 1_000.0, ffDecimal, 1) & "us"
  else:
    formatFloat(ns, ffDecimal, 0) & "ns"

proc runPair(label: string, iterations: int, jsonyOp: proc(), fastjsonOp: proc(), jsonBytes: int) =
  let (jOps, jNs) = bench("jsony", iterations, jsonyOp)
  let (fOps, fNs) = bench("fastjson", iterations, fastjsonOp)
  let speedup = fOps / jOps
  let pad = 40 - label.len
  echo label, spaces(max(1, pad)),
    "jsony: ", fmtOps(jOps).align(8), " (", fmtNs(jNs).align(7), ")  ",
    "fastjson: ", fmtOps(fOps).align(8), " (", fmtNs(fNs).align(7), ")  ",
    formatFloat(speedup, ffDecimal, 2), "x",
    "  [", jsonBytes, "B]"

when isMainModule:
  let iterations =
    if paramCount() > 0: parseInt(paramStr(1))
    else: 50000
  let seqSize = 32

  echo "=== nim_fastjson benchmark: varied input types ==="
  echo "iterations: ", iterations, "  seq size: ", seqSize
  echo ""

  # --- Serialization ---
  echo "--- SERIALIZE ---"
  echo ""

  block: # Int-heavy
    let data = sampleMetrics(seqSize)
    let json = jsony.toJson(data)
    runPair("int-heavy (8 int fields x" & $seqSize & ")", iterations,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  block: # String-heavy
    let data = sampleUsers(seqSize)
    let json = jsony.toJson(data)
    runPair("string-heavy (8 str fields x" & $seqSize & ")", iterations,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  block: # Float-heavy
    let data = samplePrices(seqSize)
    let json = jsony.toJson(data)
    runPair("float-heavy (6 float fields x" & $seqSize & ")", iterations,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  block: # Mixed (original Todo)
    let data = sampleTodos(seqSize)
    let json = jsony.toJson(data)
    runPair("mixed int/str/bool x" & $seqSize, iterations,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  block: # Long strings
    let data = sampleArticles(seqSize)
    let json = jsony.toJson(data)
    runPair("long-strings (~200ch body x" & $seqSize & ")", iterations,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  block: # Nested objects
    let data = samplePeople(seqSize)
    let json = jsony.toJson(data)
    runPair("nested objects (3-level x" & $seqSize & ")", iterations,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  block: # Flat single object
    let data = Config(host: "api.example.com", port: 8080, debug: false,
                      maxRetries: 3, timeout: 30.5, region: "us-east-1")
    let json = jsony.toJson(data)
    runPair("flat single object (6 fields)", iterations * 4,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  block: # Primitive seq[int]
    let data = sampleIntArray(seqSize)
    let json = jsony.toJson(data)
    runPair("seq[int] x" & $seqSize, iterations * 2,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  block: # Primitive seq[string]
    let data = sampleStringArray(seqSize)
    let json = jsony.toJson(data)
    runPair("seq[string] x" & $seqSize, iterations * 2,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  block: # Large seq (128 items)
    let data = sampleTodos(128)
    let json = jsony.toJson(data)
    runPair("mixed x128 (large seq)", iterations div 2,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  block: # Small seq (4 items)
    let data = sampleTodos(4)
    let json = jsony.toJson(data)
    runPair("mixed x4 (small seq)", iterations * 4,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  echo ""
  echo "--- DESERIALIZE ---"
  echo ""

  block: # Int-heavy
    let json = jsony.toJson(sampleMetrics(seqSize))
    runPair("int-heavy (8 int fields x" & $seqSize & ")", iterations,
      proc() = discard jsony.fromJson(json, MetricsReport),
      proc() = discard deserialize(json, MetricsReport),
      json.len)

  block: # String-heavy
    let json = jsony.toJson(sampleUsers(seqSize))
    runPair("string-heavy (8 str fields x" & $seqSize & ")", iterations,
      proc() = discard jsony.fromJson(json, UserDirectory),
      proc() = discard deserialize(json, UserDirectory),
      json.len)

  block: # Float-heavy
    let json = jsony.toJson(samplePrices(seqSize))
    runPair("float-heavy (6 float fields x" & $seqSize & ")", iterations,
      proc() = discard jsony.fromJson(json, TimeSeries),
      proc() = discard deserialize(json, TimeSeries),
      json.len)

  block: # Mixed
    let json = jsony.toJson(sampleTodos(seqSize))
    runPair("mixed int/str/bool x" & $seqSize, iterations,
      proc() = discard jsony.fromJson(json, Envelope),
      proc() = discard deserialize(json, Envelope),
      json.len)

  block: # Long strings
    let json = jsony.toJson(sampleArticles(seqSize))
    runPair("long-strings (~200ch body x" & $seqSize & ")", iterations,
      proc() = discard jsony.fromJson(json, ArticleFeed),
      proc() = discard deserialize(json, ArticleFeed),
      json.len)

  block: # Nested objects
    let json = jsony.toJson(samplePeople(seqSize))
    runPair("nested objects (3-level x" & $seqSize & ")", iterations,
      proc() = discard jsony.fromJson(json, PeopleList),
      proc() = discard deserialize(json, PeopleList),
      json.len)

  block: # Flat single object
    let json = jsony.toJson(Config(host: "api.example.com", port: 8080, debug: false,
                                    maxRetries: 3, timeout: 30.5, region: "us-east-1"))
    runPair("flat single object (6 fields)", iterations * 4,
      proc() = discard jsony.fromJson(json, Config),
      proc() = discard deserialize(json, Config),
      json.len)

  block: # Large seq
    let json = jsony.toJson(sampleTodos(128))
    runPair("mixed x128 (large seq)", iterations div 2,
      proc() = discard jsony.fromJson(json, Envelope),
      proc() = discard deserialize(json, Envelope),
      json.len)

  block: # Small seq
    let json = jsony.toJson(sampleTodos(4))
    runPair("mixed x4 (small seq)", iterations * 4,
      proc() = discard jsony.fromJson(json, Envelope),
      proc() = discard deserialize(json, Envelope),
      json.len)
