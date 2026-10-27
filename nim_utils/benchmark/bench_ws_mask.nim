## WebSocket mask/unmask benchmark: encodeWsFrame+decodeWsFrame round-trip,
## SSE2 (default) vs portable (-d:nimWsFramePortable). Verifies correctness.
import std/[monotimes, options]
import nim_fasthttpclient/[ws_frame, types]

proc nowNs(): int64 = getMonoTime().ticks div 1000

for size in [256, 4096, 65536]:
  var payload = newString(size)
  for i in 0 ..< size: payload[i] = char((i * 7) and 0xFF)

  # correctness round-trip
  let frame = encodeWsFrame(woText, payload, masked = true)
  var pos = 0
  var db = newSeqOfCap[byte](frame.len); db.setLen(frame.len)
  copyMem(addr db[0], unsafeAddr frame[0], frame.len)
  let dec = decodeWsFrame(db, pos)
  doAssert(dec.isSome(), "decode failed")
  doAssert(dec.get().payload == payload, "round-trip mismatch")

  const iters = 20_000
  # warmup
  var sink = 0
  for _ in 0 ..< 200:
    let f = encodeWsFrame(woText, payload, masked = true)
    var p = 0
    var db2 = newSeqOfCap[byte](f.len); db2.setLen(f.len)
    copyMem(addr db2[0], unsafeAddr f[0], f.len)
    let d = decodeWsFrame(db2, p)
    if d.isSome(): sink += d.get().payload.len
  discard sink
  var t0 = nowNs()
  for _ in 0 ..< iters:
    let f = encodeWsFrame(woText, payload, masked = true)
    var p = 0
    var db2 = newSeqOfCap[byte](f.len); db2.setLen(f.len)
    copyMem(addr db2[0], unsafeAddr f[0], f.len)
    let d = decodeWsFrame(db2, p)
    if d.isSome(): sink += d.get().payload.len
  let ns = nowNs() - t0
  echo "size " & $size & ": " & $iters & " encode+decode in " & $ns &
       " ns  (" & $(ns.float64 / iters.float64) & " us/op)"
