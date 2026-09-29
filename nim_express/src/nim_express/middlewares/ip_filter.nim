## IP filter middleware (allowlist / denylist with CIDR support).

import std/[asyncdispatch, strutils, parseutils]
import common

type
  CidrEntry* = object
    addrBytes*: array[16, uint8]
    prefixLen*: int
    isV6*: bool
    isValid*: bool

  IpFilterOptions* = object
    allowlist*: seq[string]
    denylist*: seq[string]
    denyStatusCode*: int
    denyMessage*: string
    trustProxy*: bool
    onWarning*: proc(msg: string)

## Returns the default IP filter options, with both lists empty and 403 as the deny status.
proc defaultIpFilterOptions*(): IpFilterOptions {.inline.} =
  IpFilterOptions(
    allowlist: @[],
    denylist: @[],
    denyStatusCode: 403,
    denyMessage: "Forbidden",
    trustProxy: false,
    onWarning: nil
  )

## Parses a dotted-decimal IPv4 address into the first four bytes of `output`, returning false on invalid input.
proc parseIpv4Bytes*(ip: string, output: var array[16, uint8]): bool {.noSideEffect.} =
  ## Parse dotted-decimal IPv4 into bytes 0..3 of output. Returns false on error.
  var parts: array[4, int]
  var partIdx = 0
  var i = 0
  while i < ip.len and partIdx < 4:
    var num = 0
    let consumed = parseInt(ip, num, i)
    if consumed == 0:
      return false
    if num < 0 or num > 255:
      return false
    parts[partIdx] = num
    i += consumed
    inc partIdx
    if i < ip.len:
      if ip[i] != '.':
        return false
      inc i
  if partIdx != 4 or i != ip.len:
    return false
  for idx in 0..3:
    output[idx] = uint8(parts[idx])
  true

## Parses an IPv6 address, including double-colon shorthand and IPv4-mapped suffixes, into the sixteen `output` bytes.
proc parseIpv6Bytes*(ip: string, output: var array[16, uint8]): bool {.noSideEffect.} =
  ## Simplified IPv6 parser supporting :: shorthand and IPv4-mapped forms.
  var groups: array[8, uint16]
  var groupIdx = 0
  var doubleColonIdx = -1
  var i = 0

  # Handle leading ::
  if ip.len >= 2 and ip[0] == ':' and ip[1] == ':':
    doubleColonIdx = 0
    i = 2

  while i < ip.len and groupIdx < 8:
    if ip[i] == ':':
      if i + 1 < ip.len and ip[i + 1] == ':':
        if doubleColonIdx >= 0:
          return false  # Only one :: allowed.
        doubleColonIdx = groupIdx
        i += 2
        continue
      inc i
      continue

    # Check for IPv4-mapped suffix (e.g., ::ffff:192.168.1.1). Requires at
    # least one preceding group; ::a.b.c.d (IPv4-compatible, deprecated by
    # RFC 4291) is not supported. The dotCount == 3 check is the real
    # discriminator, so no false positives on pure-hex groups.
    var maybeV4 = false
    if groupIdx >= 6 or (doubleColonIdx >= 0 and groupIdx >= 1):
      var j = i
      var dotCount = 0
      while j < ip.len:
        if ip[j] == '.':
          inc dotCount
        j += 1
      if dotCount == 3:
        maybeV4 = true

    if maybeV4:
      var v4Bytes: array[16, uint8]
      if parseIpv4Bytes(ip[i..^1], v4Bytes):
        # Place into last two groups; more than 6 hex groups before the
        # suffix would exceed 8 groups total (or clobber parsed groups).
        if groupIdx > 6:
          return false
        let targetGroup =
          if doubleColonIdx >= 0: groupIdx
          else: 6
        groups[targetGroup] = (uint16(v4Bytes[0]) shl 8) or uint16(v4Bytes[1])
        groups[targetGroup + 1] = (uint16(v4Bytes[2]) shl 8) or uint16(v4Bytes[3])
        groupIdx = targetGroup + 2
        i = ip.len
        break
      # Not valid IPv4 suffix; fall through to hex parsing.

    var hexVal: int = 0
    let consumed = parseHex(ip, hexVal, i)
    if consumed == 0:
      return false
    if hexVal < 0 or hexVal > 0xFFFF:
      return false
    groups[groupIdx] = uint16(hexVal)
    inc groupIdx
    i += consumed

  if i != ip.len:
    return false  # Leftover input after 8 groups (too many groups).

  # Expand :: zero-fill.
  if doubleColonIdx >= 0:
    let filled = groupIdx
    let zerosNeeded = 8 - filled
    if zerosNeeded < 0:
      return false
    # Shift groups after doubleColonIdx to the right.
    for j in countdown(7, doubleColonIdx + zerosNeeded):
      let srcIdx = j - zerosNeeded
      if srcIdx >= doubleColonIdx and srcIdx < filled:
        groups[j] = groups[srcIdx]
      else:
        groups[j] = 0'u16
    for j in doubleColonIdx ..< doubleColonIdx + zerosNeeded:
      groups[j] = 0'u16
  elif groupIdx != 8:
    return false

  for g in 0..7:
    output[g * 2] = uint8(groups[g] shr 8)
    output[g * 2 + 1] = uint8(groups[g] and 0xFF)
  true

## Parses an IP or CIDR entry string into a `CidrEntry`, defaulting the prefix to 32 for IPv4 and 128 for IPv6.
proc parseCidr*(entry: string): CidrEntry {.noSideEffect.} =
  let slashIdx = entry.find('/')
  var ipPart: string
  var hasPrefix = false
  var prefixLen = 0

  if slashIdx >= 0:
    ipPart = entry[0 ..< slashIdx].strip()
    let prefixStr = entry[slashIdx + 1 .. ^1].strip()
    try:
      prefixLen = parseInt(prefixStr)
    except ValueError:
      return CidrEntry()
    if prefixLen < 0:
      return CidrEntry()
    hasPrefix = true
  else:
    ipPart = entry.strip()

  if ipPart.len == 0:
    return CidrEntry()

  var addrBytes: array[16, uint8]

  # Try IPv4 first.
  if parseIpv4Bytes(ipPart, addrBytes):
    if not hasPrefix:
      prefixLen = 32
    elif prefixLen > 32:
      return CidrEntry()
    return CidrEntry(addrBytes: addrBytes, prefixLen: prefixLen, isV6: false, isValid: true)

  # Try IPv6.
  if parseIpv6Bytes(ipPart, addrBytes):
    if not hasPrefix:
      prefixLen = 128
    elif prefixLen > 128:
      return CidrEntry()
    return CidrEntry(addrBytes: addrBytes, prefixLen: prefixLen, isV6: true, isValid: true)

  CidrEntry()

## Returns true if the sixteen bytes form an IPv4-mapped IPv6 address with the ffff transition prefix.
proc isIpv4MappedIpv6*(bytes: array[16, uint8]): bool {.inline, noSideEffect.} =
  for i in 0..9:
    if bytes[i] != 0:
      return false
  bytes[10] == 0xFF and bytes[11] == 0xFF

## Copies the trailing four bytes of an IPv4-mapped IPv6 address into `output`.
proc extractMappedIpv4*(v6Bytes: array[16, uint8], output: var array[16, uint8]) {.inline, noSideEffect.} =
  output[0] = v6Bytes[12]
  output[1] = v6Bytes[13]
  output[2] = v6Bytes[14]
  output[3] = v6Bytes[15]

## Matches pre-parsed client IP bytes against a CIDR entry, normalizing IPv4-mapped IPv6 addresses across families.
proc matchesCidrBytes*(
  ipBytes: array[16, uint8], ipIsV6: bool, cidr: CidrEntry
): bool {.inline, noSideEffect.} =
  ## Match pre-parsed client IP bytes against a CIDR entry.
  if not cidr.isValid:
    return false
  var ipBytes = ipBytes
  var ipIsV6 = ipIsV6

  if not cidr.isV6 and ipIsV6:
    if isIpv4MappedIpv6(ipBytes):
      var mapped: array[16, uint8]
      extractMappedIpv4(ipBytes, mapped)
      ipBytes = mapped
      ipIsV6 = false
    else:
      return false
  elif cidr.isV6 and not ipIsV6:
    var v6Bytes: array[16, uint8]
    for i in 0..9:
      v6Bytes[i] = 0
    v6Bytes[10] = 0xFF
    v6Bytes[11] = 0xFF
    v6Bytes[12] = ipBytes[0]
    v6Bytes[13] = ipBytes[1]
    v6Bytes[14] = ipBytes[2]
    v6Bytes[15] = ipBytes[3]
    ipBytes = v6Bytes
    ipIsV6 = true

  let totalBits = cidr.prefixLen
  let fullBytes = totalBits div 8
  let remainingBits = totalBits mod 8

  let maxByte =
    if cidr.isV6: 16
    else: 4

  for i in 0 ..< min(fullBytes, maxByte):
    if ipBytes[i] != cidr.addrBytes[i]:
      return false

  if remainingBits > 0 and fullBytes < maxByte:
    let mask = uint8(0xFF shl (8 - remainingBits))
    if (ipBytes[fullBytes] and mask) != (cidr.addrBytes[fullBytes] and mask):
      return false

  true

## Filters requests by client IP using an allowlist and/or denylist with CIDR range support, rejecting non-matching clients.
proc ipFilter*(
  options: IpFilterOptions = defaultIpFilterOptions()
): AsyncMiddleware =
  ## Filter requests by client IP address using allowlist and/or denylist
  ## with CIDR range support.
  ##
  ## Cross-family matching normalizes IPv4-mapped IPv6 addresses
  ## (::ffff:a.b.c.d) in both directions. Known limitation: IPv4-compatible
  ## IPv6 addresses (::a.b.c.d, deprecated by RFC 4291) are not normalized
  ## and will not match IPv4 CIDR entries.
  let opts = options
  # A zero/negative denyStatusCode means "unset" (object construction
  # zero-initializes omitted fields); fall back to the documented default.
  let denyStatus =
    if opts.denyStatusCode <= 0: 403
    else: max(400, min(599, opts.denyStatusCode))
  let warn =
    if opts.onWarning.isNil:
      proc(msg: string) =
        stderr.writeLine("[ip_filter] WARNING: ", msg)
    else:
      opts.onWarning

  # Pre-parse CIDR entries at middleware creation time.
  var parsedAllow = newSeqOfCap[CidrEntry](opts.allowlist.len)
  for entry in opts.allowlist:
    let cidr = parseCidr(entry)
    if cidr.isValid:
      parsedAllow.add(cidr)
    else:
      warn("skipping invalid CIDR entry: " & entry)

  var parsedDeny = newSeqOfCap[CidrEntry](opts.denylist.len)
  for entry in opts.denylist:
    let cidr = parseCidr(entry)
    if cidr.isValid:
      parsedDeny.add(cidr)
    else:
      warn("skipping invalid CIDR entry: " & entry)

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    var clientIp = req.native.remoteIp
    let trustForwarded = opts.trustProxy or req.trustProxyEnabled
    # trustedClientIp re-checks forwardedHeadersTrusted internally and
    # returns "" when forwarded headers are not trusted.
    let forwarded = req.trustedClientIp(trustProxyEnabled = trustForwarded)
    if forwarded.len > 0:
      clientIp = forwarded

    if clientIp.len == 0:
      res.status(denyStatus).send(opts.denyMessage)
      return

    # Parse the client IP once; every CIDR check operates on the bytes.
    var ipBytes: array[16, uint8]
    var ipIsV6 = false
    if parseIpv4Bytes(clientIp, ipBytes):
      ipIsV6 = false
    elif parseIpv6Bytes(clientIp, ipBytes):
      ipIsV6 = true
    else:
      # Unparseable client IP matches no CIDR entry.
      if parsedAllow.len > 0:
        res.status(denyStatus).send(opts.denyMessage)
        return
      await next()
      return

    # Check denylist first.
    if parsedDeny.len > 0:
      for cidr in parsedDeny:
        if matchesCidrBytes(ipBytes, ipIsV6, cidr):
          res.status(denyStatus).send(opts.denyMessage)
          return

    # If allowlist is configured, IP must match at least one entry.
    if parsedAllow.len > 0:
      var allowed = false
      for cidr in parsedAllow:
        if matchesCidrBytes(ipBytes, ipIsV6, cidr):
          allowed = true
          break
      if not allowed:
        res.status(denyStatus).send(opts.denyMessage)
        return

    await next()
