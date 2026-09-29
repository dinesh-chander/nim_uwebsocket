import std/[random, strutils, options, tables]
import ../nim_utils/src/nim_utils/nim_fastjson/direct_engine

const
  Iterations = 10_000
  ProgressInterval = 1000

var rng = initRand(42)
var failures: seq[string]

proc hexDump(data: string): string =
  for i, c in data:
    if i > 0 and i mod 32 == 0: result.add "\n"
    result.add toHex(ord(c), 2) & " "

proc fail(label, msg: string, data: string = "") =
  var entry = label & ": " & msg
  if data.len > 0:
    let preview = data[0 ..< min(data.len, 200)]
    entry.add "\ninput: " & preview.repr
  failures.add entry

proc randomBytes(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(255))

proc randomPrintable(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(93) + 33)

type
  FlatObj = object
    name: string
    value: int
    active: bool

  NestedObj = object
    inner: Option[FlatObj]
    tags: seq[string]

  DeepObj = ref object
    child: DeepObj
    label: string

  MapObj = object
    data: Table[string, string]

proc tryDeserialize[T](label: string, json: string, _: typedesc[T]) =
  try:
    let parsed = deserializeDirect(json, T)
    discard parsed
  except JsonError:
    discard
  except ValueError:
    discard
  except CatchableError:
    discard
  except Defect as e:
    fail(label, "Defect: " & e.msg, json)

echo "=== Fuzz JSON Parser ==="

echo "--- Category 1: Random bytes as JSON ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let data = randomBytes(rng.rand(512) + 1)
  tryDeserialize("random_bytes_" & $i, data, FlatObj)

echo "--- Category 2: Deeply nested objects ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let depth = rng.rand(800) + 50
  var json = ""
  for d in 0 ..< depth:
    json.add "{\"child\":"
  json.add "null"
  for d in 0 ..< depth:
    json.add ",\"label\":\"x\"}"
  tryDeserialize("deep_nested_" & $i, json, DeepObj)

echo "--- Category 3: Deeply nested arrays ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let depth = rng.rand(800) + 50
  var json = ""
  for d in 0 ..< depth:
    json.add "["
  json.add "1"
  for d in 0 ..< depth:
    json.add "]"
  tryDeserialize("deep_array_" & $i, json, seq[int])

echo "--- Category 4: Very long strings ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let strLen = rng.rand(100_000) + 1000
  var longStr = newString(strLen)
  for j in 0 ..< strLen:
    longStr[j] = char(rng.rand(25) + ord('a'))
  let json = "\"" & longStr & "\""
  tryDeserialize("long_string_" & $i, json, string)

echo "--- Category 5: Unicode edge cases ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let variant = rng.rand(7)
  var json: string
  case variant
  of 0: json = "\"\\uD800\""
  of 1: json = "\"\\uDC00\""
  of 2: json = "\"\\uD800\\uDC00\""
  of 3: json = "\"\\uD800\\u0041\""
  of 4: json = "\"\\u0000\""
  of 5: json = "\"\\uFFFE\""
  of 6: json = "\"\\uFFFF\""
  else:
    let cp = rng.rand(0xFFFF)
    json = "\"\\u" & toHex(cp, 4) & "\""
  tryDeserialize("unicode_" & $i, json, string)

echo "--- Category 6: Number edge cases ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let variant = rng.rand(11)
  var json: string
  case variant
  of 0: json = "1e999999"
  of 1: json = "-1e999999"
  of 2: json = "0.0000000000000000000000000001"
  of 3: json = "00123"
  of 4: json = "-0"
  of 5: json = "-0.0"
  of 6: json = "1e+"
  of 7: json = "1e-"
  of 8: json = "."
  of 9: json = "-."
  of 10: json = "1e" & $rng.rand(1000)
  else: json = $rng.rand(int.high)
  tryDeserialize("number_int_" & $i, json, int)
  tryDeserialize("number_float_" & $i, json, float)

echo "--- Category 7: Null bytes in strings ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  var inner = randomPrintable(rng.rand(50))
  let nullPos = rng.rand(inner.len)
  inner.insert("\0", nullPos)
  let json = "{\"name\":\"" & inner & "\",\"value\":0,\"active\":false}"
  tryDeserialize("null_in_str_" & $i, json, FlatObj)

echo "--- Category 8: Truncated JSON ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let full = "{\"name\":\"hello\",\"value\":42,\"active\":true}"
  let cutPoint = rng.rand(full.len)
  let truncated = full[0 ..< cutPoint]
  tryDeserialize("truncated_" & $i, truncated, FlatObj)

echo "--- Category 9: Roundtrip (serialize -> deserialize -> compare) ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let original = FlatObj(
    name: randomPrintable(rng.rand(100)),
    value: rng.rand(int.high),
    active: rng.rand(1) == 1
  )
  try:
    let serialized = serializeDirect(original)
    let roundtripped = deserializeDirect(serialized, FlatObj)
    if roundtripped.name != original.name:
      fail("roundtrip_" & $i, "name mismatch: " & original.name.repr & " vs " & roundtripped.name.repr)
    if roundtripped.value != original.value:
      fail("roundtrip_" & $i, "value mismatch")
    if roundtripped.active != original.active:
      fail("roundtrip_" & $i, "active mismatch")
  except CatchableError as e:
    fail("roundtrip_" & $i, "exception: " & e.msg)
  except Defect as e:
    fail("roundtrip_" & $i, "Defect: " & e.msg)

echo "--- Category 10: Malformed structural tokens ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let variant = rng.rand(12)
  var json: string
  case variant
  of 0: json = "{"
  of 1: json = "}"
  of 2: json = "["
  of 3: json = "]"
  of 4: json = ","
  of 5: json = ":"
  of 6: json = "{\"name\":}"
  of 7: json = "{:\"value\"}"
  of 8: json = "[,]"
  of 9: json = "{\"a\":1,}"
  of 10: json = "nul"
  of 11: json = "tru"
  else: json = "fals"
  tryDeserialize("malformed_token_" & $i, json, FlatObj)
  tryDeserialize("malformed_token_str_" & $i, json, string)

echo "--- Category 11: Table/Map deserialization ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  var json = "{"
  let numKeys = rng.rand(50)
  for j in 0 ..< numKeys:
    if j > 0: json.add ","
    let key = randomPrintable(rng.rand(30) + 1)
    let val = randomPrintable(rng.rand(30))
    json.add "\"" & key & "\":\"" & val & "\""
  json.add "}"
  tryDeserialize("table_" & $i, "{\"data\":" & json & "}", MapObj)

echo "--- Category 12: Seq deserialization stress ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  var json = "["
  let count = rng.rand(500)
  for j in 0 ..< count:
    if j > 0: json.add ","
    json.add $rng.rand(int.high)
  json.add "]"
  tryDeserialize("seq_stress_" & $i, json, seq[int])

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All JSON parser fuzz tests passed (", Iterations * 12, " total iterations)"
  quit(0)
