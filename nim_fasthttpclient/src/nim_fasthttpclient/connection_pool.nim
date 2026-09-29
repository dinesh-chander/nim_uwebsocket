import std/[tables, times, deques]
import types

## Build the pool table key identifying a host, port, and SSL mode.
proc poolKey*(host: string, port: uint16, useSsl: bool): string {.inline.} =
  result = newStringOfCap(host.len + 8)
  if useSsl:
    result.add "s:"
  else:
    result.add "p:"
  result.add host
  result.add ":"
  result.addInt int(port)

## Create a connection pool with per-host limits and an idle timeout.
proc initConnectionPool*(maxPerHost: int = 6, idleTimeoutSec: float = 60.0): ConnectionPool {.inline.} =
  result.connections = initTable[string, seq[ptr PooledConnection]](16)
  result.maxPerHost = max(1, maxPerHost)
  result.idleTimeoutSec = max(0.0, idleTimeoutSec)
  result.totalConnections = 0

## Acquire an open pooled connection for a host, or return nil if none exists.
proc acquireConnection*(pool: var ConnectionPool, host: string, port: uint16, useSsl: bool): ptr PooledConnection =
  let key = poolKey(host, port, useSsl)
  if key in pool.connections:
    let conns = addr pool.connections[key]
    var i = conns[].len - 1
    while i >= 0:
      let conn = conns[][i]
      if conn.state == csOpen:
        conn.lastUsed = epochTime()
        return conn
      i -= 1
  nil

## Acquire an idle HTTP/1 pooled connection without pending callbacks, or return nil.
proc acquireIdleH1*(pool: var ConnectionPool, host: string, port: uint16, useSsl: bool): ptr PooledConnection =
  let key = poolKey(host, port, useSsl)
  if key in pool.connections:
    let conns = addr pool.connections[key]
    for i in 0 ..< conns[].len:
      let conn = conns[][i]
      if conn.state == csOpen and not conn.isHttp2 and
         conn.pendingCallbacks.len == 0:
        conn.lastUsed = epochTime()
        return conn
  nil

## Acquire an open or connecting HTTP/2 pooled connection, or return nil.
proc acquireH2*(pool: var ConnectionPool, host: string, port: uint16, useSsl: bool): ptr PooledConnection =
  let key = poolKey(host, port, useSsl)
  if key in pool.connections:
    let conns = addr pool.connections[key]
    for i in 0 ..< conns[].len:
      let conn = conns[][i]
      if conn.isHttp2 and (conn.state == csOpen or conn.state == csConnecting):
        conn.lastUsed = epochTime()
        return conn
  nil

## Count the pooled connections currently tracked for a host.
proc countForHost*(pool: var ConnectionPool, host: string, port: uint16, useSsl: bool): int =
  let key = poolKey(host, port, useSsl)
  if key in pool.connections:
    return pool.connections[key].len
  0

## Mark a pooled connection as just used to defer idle eviction.
proc releaseConnection*(pool: var ConnectionPool, conn: ptr PooledConnection) =
  conn.lastUsed = epochTime()

## Track a new connection in the pool, closing it if its host is at capacity.
proc addConnection*(pool: var ConnectionPool, conn: ptr PooledConnection) =
  let key = poolKey(conn.host, conn.port, conn.useSsl)
  if key notin pool.connections:
    pool.connections[key] = newSeqOfCap[ptr PooledConnection](pool.maxPerHost)
  else:
    for existing in pool.connections[key]:
      if existing == conn:
        return
    if pool.connections[key].len >= pool.maxPerHost:
      conn.state = csClosed
      return
  conn.cachedPoolKey = key
  pool.connections[key].add conn
  pool.totalConnections += 1

## Remove a connection from the pool, dropping the host entry when it becomes empty.
proc removeConnection*(pool: var ConnectionPool, conn: ptr PooledConnection) =
  let key = if conn.cachedPoolKey.len > 0: conn.cachedPoolKey
            else: poolKey(conn.host, conn.port, conn.useSsl)
  if key in pool.connections:
    let conns = addr pool.connections[key]
    var i = 0
    while i < conns[].len:
      if conns[][i] == conn:
        if i < conns[].len - 1:
          conns[][i] = conns[][conns[].len - 1]
        conns[].setLen(conns[].len - 1)
        if pool.totalConnections > 0:
          pool.totalConnections -= 1
        if conns[].len == 0:
          pool.connections.del(key)
        return
      i += 1

## Remove closed and expired idle connections, returning them for socket teardown.
proc cleanup*(pool: var ConnectionPool): seq[ptr PooledConnection] =
  result = @[]
  let now = epochTime()
  var emptyKeys: seq[string] = @[]
  for key in pool.connections.keys:
    let conns = addr pool.connections[key]
    var i = conns[].len - 1
    while i >= 0:
      let conn = conns[][i]
      let hasPending =
        conn.pendingCallbacks.len > 0 or
        (conn.isHttp2 and conn.h2Streams.len > 0)
      let isClosed = conn.state == csClosed or conn.state == csClosing
      let isIdle =
        conn.state == csOpen and
        not hasPending
      if (isClosed and not hasPending) or
         (isIdle and (now - conn.lastUsed) >= pool.idleTimeoutSec):
        result.add(conn)
        conn.state = csClosed
        conns[].del(i)
        if pool.totalConnections > 0:
          pool.totalConnections -= 1
      i -= 1
    if conns[].len == 0:
      emptyKeys.add key
  for key in emptyKeys:
    pool.connections.del(key)
