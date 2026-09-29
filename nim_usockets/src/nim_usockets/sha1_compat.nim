{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}

type
  SecureSha1Hash* = sha1.SecureHash
  Sha1DigestBytes* = sha1.Sha1Digest

## Inline wrapper around ``sha1.secureHash`` from ``std/sha1`` producing the digest used for WebSocket accept-key computation.
proc secureHash*(data: string): SecureSha1Hash {.inline.} =
  sha1.secureHash(data)

proc `$`*(hash: SecureSha1Hash): string {.inline.} =
  sha1.`$`(hash)

## Returns the raw 20-byte SHA-1 digest of ``data`` as ``Sha1DigestBytes``.
proc secureHashBytes*(data: string): Sha1DigestBytes {.inline.} =
  Sha1DigestBytes(sha1.secureHash(data))
