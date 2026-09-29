## ETag middleware and validator helpers.
## Uses FNV-1a 64-bit hash for deterministic ETags.
## Shared hash/match primitives live in etag_core.nim (single source of truth).
## Relies on response layer to compute and set the ETag header after body is ready.

import std/[asyncdispatch, strutils]
import common
import etag_core

export etag_core

type
  ETagMode* = enum
    etWeak
    etStrong

  ETagOptions* = object
    mode*: ETagMode
    allowedMethods*: set[HttpMethod]
    respectExistingHeader*: bool

const
  EtagLocalEnabled* = "_etag_enabled"
  EtagLocalMode* = "_etag_mode"
  EtagLocalAllowedMethods* = "_etag_allowed_methods"
  EtagLocalRespectExisting* = "_etag_respect_existing"
## Returns ETagOptions defaults: weak mode, ``hmGet`` and ``hmHead`` only, existing ETag headers respected.
proc defaultETagOptions*(): ETagOptions {.inline, noSideEffect.} =
  ETagOptions(
    mode: etWeak,
    allowedMethods: {hmGet, hmHead},
    respectExistingHeader: true
  )

proc hexU64(value: uint64): string {.inline, noSideEffect.} =
  toHex(value, 16)

proc allowedMethodsCsv(methods: set[HttpMethod]): string {.noSideEffect.} =
  for methodKind in [hmGet, hmHead, hmPost, hmPut, hmDelete, hmPatch, hmOptions, hmConnect, hmTrace]:
    if methodKind notin methods:
      continue
    if result.len > 0:
      result.add(',')
    result.add(methodToken(methodKind))
## Builds an ETag for content from its length and ``stableHash64`` digest, weak or strong per ``mode``.
proc generateETag*(content: string, mode: ETagMode): string {.noSideEffect.} =
  var payload = newStringOfCap(32)
  fastIntToStr(content.len, payload)
  payload.add(':')
  payload.add(hexU64(stableHash64(content)))
  case mode
  of etWeak:
    result = "W/\"" & payload & "\""
  of etStrong:
    result = "\"" & payload & "\""
## Builds a weak-mode ETag for content by delegating to the two-argument overload.
proc generateETag*(content: string): string {.inline, noSideEffect.} =
  generateETag(content, etWeak)
## Builds the etag middleware that stores mode, allowed methods, and header policy in response locals.
proc etag*(
  options: ETagOptions = defaultETagOptions()
): AsyncMiddleware =
  let opts = options
  let modeToken = if opts.mode == etStrong: "strong" else: "weak"
  let methodsCsv = allowedMethodsCsv(opts.allowedMethods)
  let respectExisting = if opts.respectExistingHeader: "1" else: "0"

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    res.locals[EtagLocalEnabled] = "1"
    res.locals[EtagLocalMode] = modeToken
    res.locals[EtagLocalAllowedMethods] = methodsCsv
    res.locals[EtagLocalRespectExisting] = respectExisting
    await next()
