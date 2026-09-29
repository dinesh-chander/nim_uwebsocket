import std/[times]
import ../nim_express/src/nim_express
import ../nim_express/src/nim_express/fastrand
import ../nim_express/src/nim_express/response

seedFastRand(uint64(getTime().toUnix()))

const
  SmallEventCount = 100
  LargeEventCount = 10
  LargePayloadSize = 1024
  BatchSize = 20

proc buildSmallPayload(seq_num: int): string =
  var buf = newStringOfCap(48)
  buf.add("{\"time\":")
  fastIntToStr(int(getTime().toUnix()), buf)
  buf.add(",\"seq\":")
  fastIntToStr(seq_num, buf)
  buf.add("}")
  buf

proc buildLargePayload(seq_num: int): string =
  var buf = newStringOfCap(LargePayloadSize + 64)
  buf.add("{\"time\":")
  fastIntToStr(int(getTime().toUnix()), buf)
  buf.add(",\"seq\":")
  fastIntToStr(seq_num, buf)
  buf.add(",\"data\":\"")
  let padLen = LargePayloadSize - buf.len - 2
  for i in 0..<padLen:
    buf.add(chr(ord('A') + (i mod 26)))
  buf.add("\"}")
  buf

var idBuf: string

proc formatId(n: int): string =
  idBuf.setLen(0)
  fastIntToStr(n, idBuf)
  idBuf

let app = newExpressApp()
app.server.options.minimalHeaderParsing = true

app.get("/sse") do (req: Request, res: Response):
  if not res.sseStart():
    return
  for i in 1..SmallEventCount:
    let payload = buildSmallPayload(i)
    if not res.sseEvent(payload, id = formatId(i)):
      return
  discard res.sseEnd(closeAfterWrite = true)

app.get("/sse/batch") do (req: Request, res: Response):
  if not res.sseStart():
    return
  var batch = res.sseBatchStart()
  for i in 1..SmallEventCount:
    let payload = buildSmallPayload(i)
    sseBatchEvent(batch, payload, id = formatId(i))
    if i mod BatchSize == 0:
      if not res.sseBatchFlush(batch):
        return
  if batch.len > 0:
    if not res.sseBatchFlush(batch):
      return
  discard res.sseEnd(closeAfterWrite = true)

app.get("/sse/large") do (req: Request, res: Response):
  if not res.sseStart():
    return
  for i in 1..LargeEventCount:
    let payload = buildLargePayload(i)
    if not res.sseEvent(payload, event = "bigdata", id = formatId(i)):
      return
  discard res.sseEnd(closeAfterWrite = true)

app.get("/health") do (req: Request, res: Response):
  res.send("ok")

echo "SSE benchmark server on http://localhost:3005"
app.run(3005)
