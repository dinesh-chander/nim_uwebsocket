## FastJSON DESERIALIZE benchmark (string-heavy): SSE2 decode scans
## (scanStringEndWithHigh + containsHighByte) vs portable (-d:nimFastjsonPortable).
import std/[monotimes]
import nim_utils/nim_fastjson

type
  Rec = object
    a: string
    b: string
    c: string
    n: int
  Doc = object
    items: seq[Rec]

const
  A = "the quick brown fox jumps over the lazy dog "
  B = "alpha beta gamma delta epsilon zeta "
  C = "0123456789abcdefghijklmnop "

proc kv(r: var string, k, v: string) =
  r.add('"')
  r.add(k)
  r.add('"')
  r.add(':')
  r.add('"')
  r.add(v)
  r.add('"')

# Build a string-heavy doc: many objects, long-ish ASCII strings (dominant case).
proc buildDoc(n: int): string =
  result = "{\"items\":["
  for i in 0 ..< n:
    if i > 0: result.add ','
    result.add '{'
    kv(result, "a", A)
    result.add ','
    kv(result, "b", B)
    result.add ','
    kv(result, "c", C)
    result.add ','
    result.add '"'
    result.add 'n'
    result.add '"'
    result.add ':'
    result.add $i
    result.add '}'
  result.add "]}"

let doc = buildDoc(200)
echo "doc bytes=" & $doc.len

let fj = initFastJson()
# warmup + correctness
let d0 = fj.deserialize(doc, Doc)
doAssert(d0.items.len == 200 and d0.items[0].n == 0 and d0.items[199].a.len > 10)
echo "decode OK items=" & $d0.items.len

const iters = 30_000
proc nowMs(): int64 = getMonoTime().ticks div 1_000_000
var t0 = nowMs()
var sink = 0
for i in 0 ..< iters:
  let d = fj.deserialize(doc, Doc)
  sink += d.items[5].n
discard sink
let ns = nowMs() - t0
echo "deserialize string-heavy: " & $iters & " in " & $ns & "ms  (" &
     $(ns.float64 * 1000.0 / iters.float64) & " us/op, " &
     $(iters.float64 / ns.float64 * 1000.0) & "k ops/s)"
