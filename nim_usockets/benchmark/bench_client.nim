import std/[net, times, strutils]

const
  Host = "127.0.0.1"
  BenchPort = 3200
  NumRequests = 10_000

let request = "GET / HTTP/1.1\r\nHost: 127.0.0.1:3200\r\nConnection: keep-alive\r\n\r\n"

proc runBenchmark(): float =
  var total = 0
  var elapsed = 0.0
  var buf = newString(4096)

  while total < NumRequests:
    let sock = newSocket()
    sock.connect(Host, Port(BenchPort))
    let batchStart = cpuTime()
    var batchCount = 0
    while total + batchCount < NumRequests:
      sock.send(request)
      let n = sock.recv(buf, 4096)
      if n <= 0:
        break
      batchCount += 1
    elapsed += cpuTime() - batchStart
    total += batchCount
    sock.close()
    if batchCount == 0:
      break

  if elapsed > 0:
    result = float(total) / elapsed
  echo "Completed: ", total, " requests in ", formatFloat(elapsed, ffDecimal, 3), "s"

let rps = runBenchmark()
echo "Requests/sec: ", formatFloat(rps, ffDecimal, 0)
