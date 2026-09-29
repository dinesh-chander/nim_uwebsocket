## Async I/O helper procs

import std/[asyncdispatch, asyncfile, httpclient]

const DefaultOutboundTimeoutMs* = 10_000

type
  IoTimeoutError* = object of CatchableError

## Read the whole file at ``path`` and return its contents.
proc readFileAsync*(path: string): Future[string] {.async.} =
  var file: AsyncFile
  try:
    file = openAsync(path, fmRead)
  except CatchableError as e:
    raise newException(IOError, "readFileAsync: failed to open " & path & ": " & e.msg)
  try:
    result = await file.readAll()
  finally:
    file.close()

## Write ``content`` to the file at ``path``, creating or truncating it.
proc writeFileAsync*(path: string, content: string): Future[void] {.async.} =
  var file: AsyncFile
  try:
    file = openAsync(path, fmWrite)
  except CatchableError as e:
    raise newException(IOError, "writeFileAsync: failed to open " & path & ": " & e.msg)
  try:
    await file.write(content)
  finally:
    file.close()

## Perform an async HTTP GET on ``url`` and return the response body, raising ``IoTimeoutError`` if it exceeds ``timeoutMs``.
proc fetchAsync*(url: string, timeoutMs: int = DefaultOutboundTimeoutMs): Future[string] {.async.} =
  let client = newAsyncHttpClient()
  let boundedTimeoutMs = max(1, timeoutMs)
  client.timeout = boundedTimeoutMs
  try:
    let reqFuture = client.getContent(url)
    if await reqFuture.withTimeout(boundedTimeoutMs):
      if reqFuture.failed:
        raise reqFuture.readError()
      result = reqFuture.read()
    else:
      raise newException(IoTimeoutError, "fetchAsync timeout after " & $boundedTimeoutMs & "ms")
  finally:
    client.close()

## Perform an async HTTP POST of ``body`` with ``contentType`` on ``url`` and return the response body, raising ``IoTimeoutError`` on timeout.
proc postAsync*(
  url: string,
  body: string,
  contentType: string = "application/json",
  timeoutMs: int = DefaultOutboundTimeoutMs
): Future[string] {.async.} =
  let client = newAsyncHttpClient()
  let boundedTimeoutMs = max(1, timeoutMs)
  client.timeout = boundedTimeoutMs
  client.headers = newHttpHeaders({"Content-Type": contentType})
  try:
    let reqFuture = client.postContent(url, body)
    if await reqFuture.withTimeout(boundedTimeoutMs):
      if reqFuture.failed:
        raise reqFuture.readError()
      result = reqFuture.read()
    else:
      raise newException(IoTimeoutError, "postAsync timeout after " & $boundedTimeoutMs & "ms")
  finally:
    client.close()
