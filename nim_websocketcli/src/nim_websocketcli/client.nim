import std/[strutils, times]
import nim_fasthttpclient/ws_client
import nim_fasthttpclient/types

export generateWebSocketKey, buildUpgradeRequest, encodeWsFrame, decodeWsFrame,
  validateUpgradeResponse, parseWsUrl, initWsClient, initWsClientForUrl,
  runWsClientLoop, connect, send, close, WsClient, WsClientState, WsOpcode, WsFrame

const
  DefaultConcurrency = 256
  DefaultDuration = 10
  DefaultPayloadSize = 64
  DefaultWorkers = 4

type
  WsClientContext* = object
    host*: string
    port*: uint16
    path*: string
    clients*: int
    duration*: int
    payloadSize*: int
    workers*: int
    warmupDuration*: int
    concurrency*: int

  ClientStats* = object
    sent*: uint64
    recv*: uint64
    errors*: uint64
    latencyMin*: float
    latencyMax*: float
    latencySum*: float

  WorkerResult* = object
    stats*: ClientStats
    duration*: float

proc parseHttpResponse*(data: string): tuple[success: bool, headers: string] =
  if data.len < 12:
    return (false, "")
  if data[0..8] != "HTTP/1.1 ":
    return (false, "")
  let status = data[9..11]
  if status != "101":
    return (false, "")
  let headerEnd = find(data, "\r\n\r\n")
  if headerEnd == -1:
    return (false, "")
  result.success = true
  result.headers = data[0..headerEnd + 3]

proc defaultContext*(): WsClientContext =
  result.host = "127.0.0.1"
  result.port = 3000
  result.path = "/"
  result.clients = DefaultConcurrency
  result.duration = DefaultDuration
  result.payloadSize = DefaultPayloadSize
  result.workers = DefaultWorkers
  result.warmupDuration = 2
  result.concurrency = DefaultConcurrency

proc helpMessage*(): string =
  result = """
WebSocket Load Testing Tool

Usage: websocketload [options]

Options:
  -h, --host <host>        Server host (default: 127.0.0.1)
  -p, --port <port>       Server port (default: 3000)
  -w, --workers <n>       Number of worker threads (default: 4)
  -c, --clients <n>       Number of concurrent clients (default: 256)
  -d, --duration <sec>   Test duration in seconds (default: 10)
  -s, --size <bytes>     Payload size in bytes (default: 64)
  -W, --warmup <sec>     Warmup duration in seconds (default: 2)
  --path <path>           WebSocket path (default: /)
  --help                  Show this help message

Examples:
  websocketload -h localhost -p 3000 -c 1000 -d 30
  websocketload --host ws.example.com --workers 8 --clients 5000
"""
