import std/[times, strformat, strutils, monotimes, options]
import ../nim_usockets/src/nim_usockets/h2_protocol

const
  WarmupIters = 1_000
  MinDurationNs = 1_000_000_000'i64

proc reportBench(label: string, totalOps: int64, elapsedNs: int64) =
  let opsPerSec = float64(totalOps) / (float64(elapsedNs) / 1e9)
  let nsPerOp = float64(elapsedNs) / float64(totalOps)
  echo &"{label:<38} {opsPerSec:>12.0f} ops/sec  ({nsPerOp:>6.1f} ns/op)"

template benchmark(benchLabel: string, body: untyped) =
  block:
    for _ in 0 ..< WarmupIters:
      body

    var totalOps = 0'i64
    let startTime = getMonoTime()
    var elapsed: int64 = 0
    while elapsed < MinDurationNs:
      for _ in 0 ..< 10_000:
        body
      totalOps += 10_000
      elapsed = (getMonoTime() - startTime).inNanoseconds
    reportBench(benchLabel, totalOps, elapsed)

proc main() =
  echo ""
  echo "HTTP/2 Frame Benchmarks"
  echo "======================="
  const hdrBench = "Benchmark"
  const hdrTput = "Throughput"
  const hdrLat = "Latency"
  echo &"{hdrBench:<38} {hdrTput:>12}          {hdrLat:>10}"
  echo "-".repeat(75)

  var buf = newStringOfCap(4096)

  benchmark "serializeFrameHeader":
    buf.setLen(0)
    serializeFrameHeader(buf, 16384, ftData, FlagEndStream, 1'u32)

  benchmark "serializeSettingsAck":
    buf.setLen(0)
    serializeSettingsAck(buf)

  benchmark "serializeSettings (default)":
    buf.setLen(0)
    serializeSettings(DefaultH2Settings, buf)

  let data1k = newString(1024)

  benchmark "serializeData (1KB)":
    buf.setLen(0)
    serializeData(1'u32, data1k, false, buf)

  benchmark "serializeDataView (1KB)":
    buf.setLen(0)
    serializeDataView(1'u32, data1k, false, buf)

  let data16k = newString(16384)

  benchmark "serializeData (16KB)":
    buf.setLen(0)
    serializeData(1'u32, data16k, false, buf)

  benchmark "serializeDataView (16KB)":
    buf.setLen(0)
    serializeDataView(1'u32, data16k, false, buf)

  var winUpdateFrame: string
  serializeWindowUpdate(1'u32, 65535'u32, winUpdateFrame)
  var winUpdateBytes = newSeq[byte](winUpdateFrame.len)
  copyMem(addr winUpdateBytes[0], addr winUpdateFrame[0], winUpdateFrame.len)

  benchmark "parseFrameHeader (WINDOW_UPD)":
    var pos = 0
    let f = parseH2Frame(winUpdateBytes, pos)
    doAssert f.isSome

  var pingFrame: string
  let pingSetup: array[8, byte] = [0x01'u8, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
  serializePing(pingSetup, false, pingFrame)
  var pingFrameBytes = newSeq[byte](pingFrame.len)
  copyMem(addr pingFrameBytes[0], addr pingFrame[0], pingFrame.len)

  benchmark "parseH2Frame (PING w/ payload)":
    var pos = 0
    let f = parseH2Frame(pingFrameBytes, pos)
    doAssert f.isSome

  let pingData: array[8, byte] = [0x01'u8, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

  benchmark "serializePing":
    buf.setLen(0)
    serializePing(pingData, false, buf)

  benchmark "serializePing (ACK)":
    buf.setLen(0)
    serializePing(pingData, true, buf)

  benchmark "serializeGoaway":
    buf.setLen(0)
    serializeGoaway(100'u32, uint32(ord(ecNoError)), buf)

  benchmark "serializeWindowUpdate":
    buf.setLen(0)
    serializeWindowUpdate(1'u32, 65535'u32, buf)

  benchmark "serializeWindowUpdate (conn)":
    buf.setLen(0)
    serializeWindowUpdate(0'u32, 65535'u32, buf)

  benchmark "coalesced WINDOW_UPDATE (2x)":
    buf.setLen(0)
    serializeWindowUpdate(0'u32, 65535'u32, buf)
    serializeWindowUpdate(1'u32, 65535'u32, buf)

  benchmark "serializeRstStream":
    buf.setLen(0)
    serializeRstStream(1'u32, uint32(ord(ecCancel)), buf)

  let headerBlock = newString(128)

  benchmark "serializeHeaders (128B block)":
    buf.setLen(0)
    serializeHeaders(1'u32, headerBlock, true, true, buf)

  benchmark "serializeTrailers (128B block)":
    buf.setLen(0)
    serializeTrailers(1'u32, headerBlock, buf)

  benchmark "parseSettings (6 params)":
    buf.setLen(0)
    serializeSettings(DefaultH2Settings, buf)
    let payload = buf[9 ..< buf.len]
    let s = parseSettings(payload)
    doAssert s.maxFrameSize == 16384

  benchmark "validateFrameLength (DATA)":
    let frame = H2Frame(length: 4096, frameType: ftData, flags: 0, streamId: 1)
    doAssert validateFrameLength(frame)

  benchmark "validateFrameLength (PING)":
    let frame = H2Frame(length: 8, frameType: ftPing, flags: 0, streamId: 0)
    doAssert validateFrameLength(frame)

  echo ""

main()
