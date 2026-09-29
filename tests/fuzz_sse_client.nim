import std/random
import ../nim_fasthttpclient/src/nim_fasthttpclient/types
import ../nim_fasthttpclient/src/nim_fasthttpclient/sse_client

const
  Iterations = 10_000
  ProgressInterval = 1000

var rng = initRand(42)
var totalIterations = 0
var failures: seq[string]

proc fail(label, msg: string) =
  failures.add label & ": " & msg

proc randomBytes(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(255))

proc randomPrintable(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(93) + 33)

template fuzzCategory(name: string, iters: int, body: untyped) =
  echo "Category: ", name
  for i {.inject.} in 0 ..< iters:
    try:
      body
    except CatchableError:
      discard
    inc totalIterations
    if totalIterations mod ProgressInterval == 0:
      echo "  progress: ", totalIterations

echo "=== Fuzz SSE Client ==="

fuzzCategory("Random byte streams fed to SSE parser", Iterations):
  var parser = initSseParser()
  let data = randomBytes(rng.rand(512) + 1)
  discard parser.feedData(data)

fuzzCategory("Very long lines (no newlines for 1MB+)", 100):
  var parser = initSseParser()
  let lineLen = 1_000_000 + rng.rand(100_000)
  var longLine = newString(lineLen)
  for j in 0 ..< lineLen:
    longLine[j] = char(rng.rand(93) + 33)
  discard parser.feedData(longLine)
  discard parser.feedData("\n\n")

fuzzCategory("Null bytes in id field", Iterations):
  var parser = initSseParser()
  let nullId = "abc\0def"
  let data = "id: " & nullId & "\ndata: hello\n\n"
  let events = parser.feedData(data)
  for ev in events:
    if '\0' in ev.id:
      fail("null_id_" & $i, "null byte leaked into event id")

fuzzCategory("Binary data in event fields", Iterations):
  var parser = initSseParser()
  let binData = randomBytes(rng.rand(100) + 1)
  let data = "event: " & binData & "\ndata: " & binData & "\n\n"
  discard parser.feedData(data)

fuzzCategory("Rapid field switching", Iterations):
  var parser = initSseParser()
  var data = ""
  let numFields = rng.rand(50) + 10
  for j in 0 ..< numFields:
    let field = ["event", "data", "id", "retry"][rng.rand(3)]
    let value = randomPrintable(rng.rand(50))
    data.add field & ": " & value & "\n"
  data.add "\n"
  discard parser.feedData(data)

fuzzCategory("Incomplete events (no trailing newline)", Iterations):
  var parser = initSseParser()
  let data = "data: hello"
  let events = parser.feedData(data)
  if events.len > 0:
    fail("incomplete_" & $i, "emitted event without blank line terminator")

fuzzCategory("retry field with non-numeric values", Iterations):
  var parser = initSseParser()
  let retryValues = ["abc", "-1", "12.5", "", "9999999999999999999",
                     "0x10", " 100", "100 ", "1e5"]
  let retryVal = retryValues[rng.rand(retryValues.high)]
  let oldRetry = parser.retryMs
  let data = "retry: " & retryVal & "\ndata: test\n\n"
  discard parser.feedData(data)
  discard oldRetry

fuzzCategory("Multiple colons in field values", Iterations):
  var parser = initSseParser()
  let numColons = rng.rand(10) + 2
  var value = ""
  for j in 0 ..< numColons:
    value.add randomPrintable(rng.rand(10) + 1) & ":"
  let data = "data: " & value & "\n\n"
  let events = parser.feedData(data)
  if events.len > 0:
    if events[0].data != value:
      fail("multi_colon_" & $i, "value mangled with multiple colons")

fuzzCategory("UTF-8 BOM handling", Iterations):
  var parser = initSseParser()
  let bom = "\xEF\xBB\xBF"
  let variant = rng.rand(2)
  var data: string
  case variant
  of 0:
    data = bom & "data: hello\n\n"
  of 1:
    data = "data: " & bom & "hello\n\n"
  else:
    data = bom & bom & "data: test\n\n"
  discard parser.feedData(data)

fuzzCategory("CR, LF, CRLF line ending mix", Iterations):
  var parser = initSseParser()
  let endings = ["\n", "\r\n", "\r"]
  var data = ""
  let numLines = rng.rand(10) + 3
  for j in 0 ..< numLines:
    let field = ["event", "data", "id"][rng.rand(2)]
    let value = randomPrintable(rng.rand(30))
    let ending = endings[rng.rand(endings.high)]
    data.add field & ": " & value & ending
  data.add "\n"
  discard parser.feedData(data)

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All SSE client fuzz tests passed (", totalIterations, " total iterations)"
  quit(0)
