import std/[unittest, strutils]

import ../src/nim_express/[windowing, response, types]

suite "Fragment windowing":
  test "parse valid items range":
    let spec = parseItemsRangeHeader("items=10-42")
    check spec.requested
    check spec.valid
    check spec.start == 10
    check spec.finish == 42
    check spec.error.len == 0

  test "reject missing or invalid range":
    let missing = parseItemsRangeHeader("")
    check not missing.valid
    check missing.error.len > 0

    let badUnit = parseItemsRangeHeader("bytes=0-9")
    check not badUnit.valid
    check "unsupported range unit" in badUnit.error

    let badOrder = parseItemsRangeHeader("items=9-2")
    check not badOrder.valid
    check "start must be <= range end" in badOrder.error

  test "windowing mode detection":
    check isWindowingModeEnabled("window", "")
    check isWindowingModeEnabled("", "true")
    check not isWindowingModeEnabled("", "")
    check not isWindowingModeEnabled("off", "0")

  test "windowed decision helper covers 206 and 416":
    let ok = resolveWindowedItemsRange("items=10-99", totalItems = 25, maxWindowItems = 256)
    check ok.statusCode == 206
    check ok.valid
    check ok.start == 10
    check ok.finish == 24
    check ok.limit == 15

    let unsat = resolveWindowedItemsRange("items=30-40", totalItems = 25, maxWindowItems = 256)
    check unsat.statusCode == 416
    check unsat.unsatisfied
    check not unsat.valid

  test "windowed decision helper rejects oversized request span":
    let tooWide = resolveWindowedItemsRange("items=0-999", totalItems = 1000, maxWindowItems = 128)
    check tooWide.statusCode == 400
    check tooWide.error.len > 0

  test "response helpers set range headers":
    var native: HttpResponse
    new(native)
    native.requestMethod = hmGet
    native.connectionClose = false

    let res = newResponse(native)
    discard res.acceptRanges("items")
    discard res.contentRange("items", 0, 9, 100)
    check res.get("accept-ranges") == "items"
    check res.get("content-range") == "items 0-9/100"

    discard res.contentRangeUnsatisfied("items", 77)
    check res.get("content-range") == "items */77"

  test "response helper applies decision headers and status":
    var native: HttpResponse
    new(native)
    native.requestMethod = hmGet
    native.connectionClose = false
    let res = newResponse(native)
    let decision = resolveWindowedItemsRange("items=3-8", totalItems = 20, maxWindowItems = 64)
    discard res.applyWindowedItemsDecision(decision, "items")
    check res.statusCode == 206
    check res.get("accept-ranges") == "items"
    check res.get("content-range") == "items 3-8/20"
