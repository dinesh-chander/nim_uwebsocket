## Compression codec selection and payload encode helpers.

import std/[strutils, algorithm]
import nim_utils/helpers/fast_map
import brotli
import brotli/encode as brotliEncode
import zstd/compress as zstdc
import libdeflate_gzip

const
  ## MIME types that are already compressed and should not be re-compressed.
  ## Shared by the compression middleware (`isPrecompressedMime`) and the
  ## response layer (`responseShouldSkipPrecompressedMime`).
  PrecompressedMimeTypes* = [
    "image/png", "image/jpeg", "image/gif", "image/webp",
    "image/avif", "image/heic",
    "video/mp4", "video/webm", "video/ogg",
    "audio/mp3", "audio/mpeg", "audio/ogg", "audio/aac",
    "application/zip", "application/gzip", "application/x-gzip",
    "application/x-bzip2", "application/x-xz", "application/zstd",
    "application/x-7z-compressed", "application/x-rar-compressed",
    "font/woff", "font/woff2"
  ]

type
  CompressionEncoding* = enum
    ceNone
    ceGzip
    ceBrotli
    ceZstd

type
  ParsedAcceptEncoding = object
    token: string
    q: float

proc bytesToString(data: openArray[byte]): string {.inline.} =
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc clamp01(value: float): float {.inline.} =
  if value < 0.0:
    return 0.0
  if value > 1.0:
    return 1.0
  value

proc parseAcceptEncodingHeader(value: string): seq[ParsedAcceptEncoding] =
  if value.len == 0:
    return @[]
  for rawPart in value.split(','):
    let part = rawPart.strip()
    if part.len == 0:
      continue
    var token = part
    var q = 1.0
    let semi = part.find(';')
    if semi >= 0:
      token = part[0..<semi].strip()
      if semi + 1 < part.len:
        let attrs = part[semi + 1..^1]
        for rawAttr in attrs.split(';'):
          let attr = rawAttr.strip()
          if attr.len < 2:
            continue
          if attr[0].toLowerAscii() != 'q' or attr[1] != '=':
            continue
          try:
            q = clamp01(parseFloat(attr[2..^1].strip()))
          except ValueError:
            q = 0.0
    token = token.toLowerAscii()
    if token == "x-gzip":
      token = "gzip"
    if token.len > 0:
      result.add(ParsedAcceptEncoding(token: token, q: q))

proc tokenForEncoding(enc: CompressionEncoding): string {.inline.} =
  case enc
  of ceGzip: "gzip"
  of ceBrotli: "br"
  of ceZstd: "zstd"
  else: ""

## Map an Accept-Encoding token like gzip, br or zstd to its CompressionEncoding value.
proc encodingFromToken*(token: string): CompressionEncoding {.inline.} =
  case token.toLowerAscii()
  of "gzip", "x-gzip": ceGzip
  of "br": ceBrotli
  of "zstd": ceZstd
  else: ceNone

## Return the header token for a CompressionEncoding, such as br or zstd.
proc headerValue*(enc: CompressionEncoding): string {.inline.} =
  tokenForEncoding(enc)

proc acceptEncodingHasQValuePtr(data: pointer, length: int): bool {.inline.} =
  let chars = cast[ptr UncheckedArray[char]](data)
  var i = 0
  while i < length:
    if chars[i] == ';':
      var j = i + 1
      while j < length and chars[j] in {' ', '\t'}:
        inc j
      if j + 1 < length:
        let c = chars[j]
        if (c == 'q' or c == 'Q') and chars[j + 1] == '=':
          return true
    inc i
  false

proc sliceEqAsciiLower(data: pointer, start: int, tokLen: int, lit: string): bool {.inline.} =
  if tokLen != lit.len:
    return false
  let chars = cast[ptr UncheckedArray[char]](data)
  var j = 0
  while j < lit.len:
    var c = chars[start + j]
    if c >= 'A' and c <= 'Z':
      c = chr(c.ord + 32)
    if c != lit[j]:
      return false
    inc j
  true

proc chooseCompressionEncodingFastPtr(data: pointer, length: int): CompressionEncoding =
  let chars = cast[ptr UncheckedArray[char]](data)
  var hasBr = false
  var hasZstd = false
  var hasGzip = false
  var hasStar = false
  var i = 0
  while i < length:
    while i < length and chars[i] in {' ', '\t'}:
      inc i
    let tokStart = i
    while i < length and chars[i] notin {',', ';', ' ', '\t'}:
      inc i
    let tokLen = i - tokStart
    if tokLen > 0:
      if tokLen == 2 and sliceEqAsciiLower(data, tokStart, tokLen, "br"):
        hasBr = true
      elif tokLen == 4 and sliceEqAsciiLower(data, tokStart, tokLen, "zstd"):
        hasZstd = true
      elif tokLen == 4 and sliceEqAsciiLower(data, tokStart, tokLen, "gzip"):
        hasGzip = true
      elif tokLen == 6 and sliceEqAsciiLower(data, tokStart, tokLen, "x-gzip"):
        hasGzip = true
      elif tokLen == 1 and chars[tokStart] == '*':
        hasStar = true
    while i < length and chars[i] != ',':
      inc i
    if i < length and chars[i] == ',':
      inc i
  var best = ceNone
  var bestQ = -1.0
  var bestRank = 99
  for candidate in [ceZstd, ceBrotli, ceGzip]:
    var hasTok = false
    case candidate
    of ceZstd:
      hasTok = hasZstd
    of ceBrotli:
      hasTok = hasBr
    of ceGzip:
      hasTok = hasGzip
    else:
      discard
    let q = if hasTok: 1.0 elif hasStar: 1.0 else: 0.0
    if q <= 0.0:
      continue
    let rank =
      case candidate
      of ceZstd: 0
      of ceBrotli: 1
      of ceGzip: 2
      else: 99
    if q > bestQ or (q == bestQ and rank < bestRank):
      bestQ = q
      bestRank = rank
      best = candidate
  best

## Fast path for choosing a compression encoding from raw Accept-Encoding characters without q-value parsing.
proc chooseCompressionEncodingFast*(acceptEncoding: openArray[char]): CompressionEncoding {.inline.} =
  if acceptEncoding.len == 0:
    return ceNone
  chooseCompressionEncodingFastPtr(unsafeAddr acceptEncoding[0], acceptEncoding.len)

proc qualityForToken(parsed: openArray[ParsedAcceptEncoding], token: string): float =
  var bestExact = -1.0
  var bestWildcard = -1.0
  for item in parsed:
    if item.token == token:
      if item.q > bestExact:
        bestExact = item.q
    elif item.token == "*":
      if item.q > bestWildcard:
        bestWildcard = item.q
  if bestExact >= 0.0:
    return bestExact
  if bestWildcard >= 0.0:
    return bestWildcard
  0.0

## Accepted encodings ordered by client q-value, with server tie-breaker zstd preferred over br and gzip.
proc acceptedEncodingsInPreferenceOrder*(acceptEncoding: string): seq[CompressionEncoding] =
  ## Ordered by client q-value and server tie-breaker: zstd > br > gzip.
  let parsed = parseAcceptEncodingHeader(acceptEncoding)
  var ranked: seq[tuple[enc: CompressionEncoding, q: float, rank: int]] = @[]
  for candidate in [ceZstd, ceBrotli, ceGzip]:
    let q = qualityForToken(parsed, tokenForEncoding(candidate))
    if q <= 0.0:
      continue
    let rank =
      case candidate
      of ceZstd: 0
      of ceBrotli: 1
      of ceGzip: 2
      else: 99
    ranked.add((candidate, q, rank))

  ranked.sort(proc(a, b: tuple[enc: CompressionEncoding, q: float, rank: int]): int =
    if a.q > b.q:
      return -1
    if a.q < b.q:
      return 1
    cmp(a.rank, b.rank)
  )

  result = newSeqOfCap[CompressionEncoding](ranked.len)
  for item in ranked:
    result.add(item.enc)

## Choose the best compression encoding from an Accept-Encoding header string.
proc chooseCompressionEncoding*(acceptEncoding: string): CompressionEncoding {.inline.} =
  if acceptEncoding.len == 0:
    return ceNone
  if not acceptEncodingHasQValuePtr(unsafeAddr acceptEncoding[0], acceptEncoding.len):
    return chooseCompressionEncodingFastPtr(unsafeAddr acceptEncoding[0], acceptEncoding.len)
  let ranked = acceptedEncodingsInPreferenceOrder(acceptEncoding)
  if ranked.len == 0:
    return ceNone
  ranked[0]

## Choose the best compression encoding from a FastStringView Accept-Encoding value.
proc chooseCompressionEncoding*(acceptEncoding: FastStringView): CompressionEncoding {.inline.} =
  if acceptEncoding.len <= 0 or acceptEncoding.data == nil:
    return ceNone
  if not acceptEncodingHasQValuePtr(acceptEncoding.data, acceptEncoding.len):
    return chooseCompressionEncodingFastPtr(acceptEncoding.data, acceptEncoding.len)
  chooseCompressionEncoding($acceptEncoding)

proc compressGzipLibdeflate(payload: string, level: int): string =
  if payload.len == 0:
    return ""
  var compressor = newCompressor(level.int32)
  var outCap = max(256, payload.len + (payload.len shr 3) + 128)
  let maxCap = max(outCap, payload.len * 8 + 4096)
  while outCap <= maxCap:
    var outBuf = newString(outCap)
    let written = compressor.compress(
      unsafeAddr payload[0],
      payload.len,
      addr outBuf[0],
      outCap
    )
    if written > 0:
      outBuf.setLen(written)
      return outBuf
    outCap = outCap shl 1
  raise newException(CatchableError, "gzip compression failed")

## Compress the payload with gzip at the given level, clamped to the libdeflate range.
proc compressGzip*(payload: string, level: int): string {.inline.} =
  compressGzipLibdeflate(payload, max(1, min(12, level)))

proc brotliModeFor(contentType: string): brotliEncode.BrotliEncoderMode {.inline.} =
  let ct = contentType.toLowerAscii()
  if ct.startsWith("text/") or
     ct.contains("json") or
     ct.contains("xml") or
     ct.contains("javascript") or
     ct.contains("ecmascript") or
     ct.contains("css") or
     ct.contains("html"):
    return brotliEncode.BrotliModeText
  brotliEncode.BrotliModeGeneric

## Compress the payload with brotli, choosing the encoder mode from the content type.
proc compressBrotliPayload*(payload: string, level: int, contentType: string = ""): string =
  let quality = max(1, min(11, level + 2))
  compressBrotli(payload, brotliModeFor(contentType), quality)

## Compress the payload with zstd at the mapped compression level.
proc compressZstdPayload*(payload: string, level: int): string =
  let zstdLevel = max(1, min(19, 1 + ((level - 1) * 2)))
  bytesToString(zstdc.compress(payload, zstdLevel))

## Compress the payload with the given encoding, returning it unchanged for ceNone.
proc compressPayload*(payload: string, encoding: CompressionEncoding, level: int, contentType: string = ""): string =
  case encoding
  of ceGzip:
    compressGzip(payload, level)
  of ceBrotli:
    compressBrotliPayload(payload, level, contentType)
  of ceZstd:
    compressZstdPayload(payload, level)
  else:
    payload
