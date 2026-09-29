## Shared ETag primitives (single source of truth for hash/match semantics).
## Consumed by the etag middleware and the response layer (RFC 7232).

import std/strutils
import ../types

## Computes the deterministic FNV-1a 64-bit hash of the content.
proc stableHash64*(content: string): uint64 {.inline, noSideEffect.} =
  ## Deterministic FNV-1a 64-bit hash.
  var h = 0xcbf29ce484222325'u64
  for c in content:
    h = h xor uint64(ord(c))
    h = h * 0x100000001b3'u64
  h

## Returns the uppercase token form of the HTTP method.
proc methodToken*(methodKind: HttpMethod): string {.inline, noSideEffect.} =
  case methodKind
  of hmGet: "GET"
  of hmPost: "POST"
  of hmPut: "PUT"
  of hmDelete: "DELETE"
  of hmPatch: "PATCH"
  of hmHead: "HEAD"
  of hmOptions: "OPTIONS"
  of hmConnect: "CONNECT"
  of hmTrace: "TRACE"

## Returns true if the method appears in the comma-separated allow list, defaulting to GET and HEAD when empty.
proc methodAllowed*(methodKind: HttpMethod, allowedCsv: string): bool {.inline, noSideEffect.} =
  if allowedCsv.len == 0:
    return methodKind == hmGet or methodKind == hmHead
  let token = methodToken(methodKind)
  var i = 0
  while i < allowedCsv.len:
    while i < allowedCsv.len and allowedCsv[i] in {' ', '\t'}:
      inc i
    let start = i
    while i < allowedCsv.len and allowedCsv[i] != ',':
      inc i
    if i - start > 0 and allowedCsv[start..<i].strip().cmpIgnoreCase(token) == 0:
      return true
    if i < allowedCsv.len:
      inc i
  false

## Removes the weak validator prefix and surrounding whitespace from an ETag.
proc stripWeakPrefix*(tag: string): string {.inline, noSideEffect.} =
  let trimmed = tag.strip()
  # Lenient on purpose: also accept lowercase "w/" for non-conformant clients.
  if trimmed.len >= 2 and (trimmed.startsWith("W/") or trimmed.startsWith("w/")):
    return trimmed[2..^1].strip()
  trimmed

## Compares two ETags with weak comparison, ignoring the weak prefix and whitespace.
proc weakEqual*(a, b: string): bool {.inline, noSideEffect.} =
  ## Weak ETag comparison (RFC 7232 §2.3): ignores W//w/ prefix and whitespace.
  ## Known minor cost: stripWeakPrefix allocates per side; acceptable because
  ## this only runs during conditional-request handling on small headers.
  stripWeakPrefix(a) == stripWeakPrefix(b)

## Returns true if the If-None-Match header value matches the ETag using weak comparison.
proc ifNoneMatchMatches*(ifNoneMatch, etag: string): bool {.inline, noSideEffect.} =
  ## Check If-None-Match against an ETag using weak comparison (RFC 7232 §3.2).
  ## Do NOT use for If-Match validation, which requires strong comparison.
  let header = ifNoneMatch.strip()
  if header.len == 0 or etag.len == 0:
    return false
  if header == "*":
    return true
  for raw in header.split(','):
    let candidate = raw.strip()
    if candidate.len == 0:
      continue
    if candidate == "*":
      return true
    if weakEqual(candidate, etag):
      return true
  false
