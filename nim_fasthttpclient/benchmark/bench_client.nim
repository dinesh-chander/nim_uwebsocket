import std/[times, monotimes, algorithm, strutils, os]
import nim_fasthttpclient/types
import nim_fasthttpclient/client

const DefaultRequests = 10000
const DefaultRounds = 5

var completedCount = 0
var errorCount = 0
var latencies: seq[float64]
var startTime: MonoTime

proc runBenchmark(numRequests: int) =
  completedCount = 0
  errorCount = 0
  latencies.setLen(0)

  var httpClient = newHttpClient(maxConnsPerHost = 64)
  startTime = getMonoTime()

  for i in 0 ..< numRequests:
    httpClient.get("http://127.0.0.1:3160/", proc(resp: HttpResponse, err: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        if err.len > 0 or resp.statusCode != 200:
          errorCount += 1
        else:
          completedCount += 1
          let elapsed = (getMonoTime() - startTime).inMicroseconds.float64 / 1000.0
          latencies.add elapsed
    )

  httpClient.run(autoStop = true)

  let endTime = getMonoTime()
  let totalMs = (endTime - startTime).inMicroseconds.float64 / 1000.0
  let totalSec = totalMs / 1000.0
  let rps = if totalSec > 0: float64(completedCount) / totalSec else: 0.0

  latencies.sort()
  let p50 = if latencies.len > 0: latencies[latencies.len * 50 div 100] else: 0.0
  let p90 = if latencies.len > 0: latencies[latencies.len * 90 div 100] else: 0.0
  let p99 = if latencies.len > 0: latencies[latencies.len * 99 div 100] else: 0.0
  let pMax = if latencies.len > 0: latencies[^1] else: 0.0

  echo "=== Benchmark Results ==="
  echo "Requests:    ", numRequests
  echo "Completed:   ", completedCount
  echo "Errors:      ", errorCount
  echo "Total time:  ", totalMs.formatFloat(ffDecimal, 2), " ms"
  echo "Req/sec:     ", rps.formatFloat(ffDecimal, 0)
  echo "p50:         ", p50.formatFloat(ffDecimal, 2), " ms"
  echo "p90:         ", p90.formatFloat(ffDecimal, 2), " ms"
  echo "p99:         ", p99.formatFloat(ffDecimal, 2), " ms"
  echo "max:         ", pMax.formatFloat(ffDecimal, 2), " ms"

  httpClient.close()

proc main() =
  let numRequests = if paramCount() > 0: parseInt(paramStr(1)) else: DefaultRequests
  let rounds = if paramCount() > 1: parseInt(paramStr(2)) else: DefaultRounds

  latencies = newSeqOfCap[float64](numRequests)

  for r in 1 .. rounds:
    echo "--- Round ", r, " ---"
    runBenchmark(numRequests)

main()
