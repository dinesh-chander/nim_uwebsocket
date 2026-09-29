## Helpers for optional HTTP range-based windowing flows.

import std/strutils

type
  ItemRangeSpec* = object
    requested*: bool
    valid*: bool
    start*: int
    finish*: int
    error*: string

  WindowedItemsDecision* = object
    requested*: bool
    valid*: bool
    unsatisfied*: bool
    statusCode*: int
    total*: int
    start*: int
    finish*: int
    limit*: int
    error*: string

## Parses an items Range header value into an `ItemRangeSpec`, reporting malformed ranges in the error field.
proc parseItemsRangeHeader*(headerValue: string): ItemRangeSpec =
  let raw = headerValue.strip()
  result.requested = raw.len > 0
  if not result.requested:
    result.error = "missing Range header; expected: items=<start>-<end>"
    return

  let eqPos = raw.find('=')
  if eqPos <= 0 or eqPos >= raw.len - 1:
    result.error = "invalid Range header; expected: items=<start>-<end>"
    return

  let unit = raw[0 ..< eqPos].strip().toLowerAscii()
  if unit != "items":
    result.error = "unsupported range unit; only items is supported"
    return

  let span = raw[(eqPos + 1) .. ^1].strip()
  if span.len == 0 or span.find(',') >= 0:
    result.error = "multiple or empty ranges are not supported"
    return

  let dashPos = span.find('-')
  if dashPos <= 0 or dashPos >= span.len - 1:
    result.error = "range must include start and end: items=<start>-<end>"
    return

  try:
    result.start = parseInt(span[0 ..< dashPos])
    result.finish = parseInt(span[(dashPos + 1) .. ^1])
  except ValueError:
    result.error = "range start/end must be integers"
    return

  if result.start < 0 or result.finish < 0:
    result.error = "range start/end must be non-negative"
    return
  if result.start > result.finish:
    result.error = "range start must be <= range end"
    return

  result.valid = true

## Returns true if a mode or window parameter value enables range-based windowing.
proc isWindowingModeEnabled*(modeValue: string, windowValue: string): bool {.inline.} =
  let mode = modeValue.strip().toLowerAscii()
  if mode == "window" or mode == "windowed" or mode == "range":
    return true

  let flag = windowValue.strip().toLowerAscii()
  flag == "1" or flag == "true" or flag == "yes" or flag == "on"

## Builds a Content-Range header value for a satisfied partial range.
proc contentRangeValue*(unit: string, startPos: int, endPos: int, total: int): string {.inline.} =
  unit & " " & $startPos & "-" & $endPos & "/" & $max(0, total)

## Builds a Content-Range header value for an unsatisfied range with the not-satisfiable spec.
proc unsatisfiedContentRangeValue*(unit: string, total: int): string {.inline.} =
  unit & " */" & $max(0, total)

## Resolves an items range request into a `WindowedItemsDecision` covering satisfied, malformed, and unsatisfied outcomes.
proc resolveWindowedItemsRange*(
  rangeHeaderValue: string,
  totalItems: int,
  maxWindowItems: int = 0
): WindowedItemsDecision =
  ## Resolve an items range into a framework-level decision object.
  ## - 400 for malformed/oversized requests
  ## - 416 for unsatisfied ranges
  ## - 206 for satisfied partial window
  let total = max(0, totalItems)
  result.total = total
  let spec = parseItemsRangeHeader(rangeHeaderValue)
  result.requested = spec.requested
  if not spec.requested:
    result.valid = true
    result.statusCode = 200
    result.start = 0
    result.finish = if total > 0: total - 1 else: -1
    result.limit = total
    return

  if not spec.valid:
    result.statusCode = 400
    result.error = spec.error
    return

  let requestedItems = spec.finish - spec.start + 1
  if maxWindowItems > 0 and requestedItems > maxWindowItems:
    result.statusCode = 400
    result.error = "requested window too large; max span is " & $maxWindowItems & " items"
    return

  if total == 0 or spec.start >= total:
    result.unsatisfied = true
    result.statusCode = 416
    result.error = "requested range is out of range"
    return

  result.valid = true
  result.statusCode = 206
  result.start = spec.start
  result.finish = min(spec.finish, total - 1)
  result.limit = result.finish - result.start + 1
