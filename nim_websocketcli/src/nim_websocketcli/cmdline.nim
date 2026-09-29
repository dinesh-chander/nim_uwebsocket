import std/[strutils, times, parseutils, monotimes, os, math]

type
  WsLoadCmd* = object
    host*: string
    port*: uint16
    path*: string
    workers*: int
    clients*: int
    duration*: int
    payloadSize*: int
    warmup*: int
    help*: bool

proc parseArgs*: WsLoadCmd =
  result.host = "127.0.0.1"
  result.port = 3000
  result.path = "/"
  result.workers = 4
  result.clients = 256
  result.duration = 10
  result.payloadSize = 64
  result.warmup = 2
  result.help = false

  for i in 1..paramCount():
    let arg = paramStr(i)
    case arg
    of "-h", "--host":
      if i < paramCount(): result.host = paramStr(i + 1)
    of "-p", "--port":
      if i < paramCount(): result.port = uint16(parseInt(paramStr(i + 1)))
    of "--path":
      if i < paramCount(): result.path = paramStr(i + 1)
    of "-w", "--workers":
      if i < paramCount(): result.workers = parseInt(paramStr(i + 1))
    of "-c", "--clients":
      if i < paramCount(): result.clients = parseInt(paramStr(i + 1))
    of "-d", "--duration":
      if i < paramCount(): result.duration = parseInt(paramStr(i + 1))
    of "-s", "--size":
      if i < paramCount(): result.payloadSize = parseInt(paramStr(i + 1))
    of "-W", "--warmup":
      if i < paramCount(): result.warmup = parseInt(paramStr(i + 1))
    of "--help", "-help":
      result.help = true
    else:
      discard
