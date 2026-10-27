## fastjson DECODE: owned `string` fields vs zero-copy `BorrowedString` fields.
import std/[monotimes]
import nim_utils/nim_fastjson
import nim_utils/nim_fastjson/borrowed

type
  OwnedItem = object
    name: string
    desc: string
    loc: string
    n: int
  OwnedDoc = object
    items: seq[OwnedItem]

  BorrowItem = object
    name: BorrowedString
    desc: BorrowedString
    loc: BorrowedString
    n: int
  BorrowDoc = object
    items: seq[BorrowItem]

const DescPrefix = "a rather long descriptive text that goes on and on "

proc buildDoc(): string =
  result = "{\"items\":["
  for i in 0 ..< 200:
    if i > 0: result.add ','
    let n = $i
    result.add "{\"name\":\"item-" & n & "\",\"desc\":\"" & DescPrefix & n &
               "\",\"loc\":\"loc-" & n & "\",\"n\":" & n & "}"
  result.add "]}"

let docJson = buildDoc()
echo "doc bytes=" & $docJson.len
const iters = 20000

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

var sink = 0
var t0 = nowMs()
for _ in 0 ..< iters:
  let fj = initFastJson()
  let d = fj.deserialize(docJson, OwnedDoc)
  sink += d.items[5].n
let ownMs = nowMs() - t0
echo "OWNED string:   " & $iters & " in " & $ownMs & "ms (" &
     $(ownMs.float64 * 1000.0 / iters.float64) & " us/decode)"

t0 = nowMs()
for _ in 0 ..< iters:
  let fj = initFastJson()
  let d = fj.deserialize(docJson, BorrowDoc)
  sink += d.items[5].n
  if d.items[5].name.toString != "item-5":
    raise newException(Exception, "borrow content mismatch")
let borMs = nowMs() - t0
echo "BORROWED:       " & $iters & " in " & $borMs & "ms (" &
     $(borMs.float64 * 1000.0 / iters.float64) & " us/decode)"
echo "speedup owned->borrowed: " & $(ownMs.float64 / max(borMs.float64, 1.0)) & "x"
discard sink
