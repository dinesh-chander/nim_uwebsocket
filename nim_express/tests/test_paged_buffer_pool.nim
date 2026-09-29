import std/unittest

import ../src/nim_express/paged_buffer

proc resetPoolState() =
  discard setPagePoolEvictionPolicy(
    maxRetainedPages = DefaultPagePoolLimit,
    maxRetainedBytes = 0'i64
  )
  discard trimPagePool(retainPages = 0, retainBytes = 0'i64)
  resetPagePoolMetrics()

suite "Paged buffer pool observability and eviction":
  test "tracks hit miss bytes and retained pages":
    resetPoolState()
    discard setPagePoolEvictionPolicy(
      maxRetainedPages = DefaultPagePoolLimit,
      maxRetainedBytes = 4096'i64
    )

    var first = initPageBuffer(32)
    first.add("abcdef")
    first.release()

    var metrics = pagePoolMetrics()
    when defined(pagepool_metrics):
      check metrics.hitCount == 0'i64
      check metrics.missCount == 1'i64
    else:
      check metrics.hitCount == 0'i64
      check metrics.missCount == 0'i64
    check metrics.retainedBytes == 32'i64
    check metrics.retainedPages == 1

    var second = initPageBuffer(32)
    second.add("z")
    metrics = pagePoolMetrics()
    when defined(pagepool_metrics):
      check metrics.hitCount == 1'i64
      check metrics.missCount == 1'i64
    else:
      check metrics.hitCount == 0'i64
      check metrics.missCount == 0'i64
    check metrics.retainedBytes == 0'i64
    check metrics.retainedPages == 0
    second.release()

  test "evicts safely by page and byte caps":
    resetPoolState()
    discard setPagePoolEvictionPolicy(maxRetainedPages = 1, maxRetainedBytes = 4096'i64)

    var pageCapped = initPageBuffer(16)
    pageCapped.add("abcdefghijklmnopqrstuvwxyz0123456789")
    pageCapped.release()

    var metrics = pagePoolMetrics()
    check metrics.retainedPages == 1
    check metrics.retainedBytes == 16'i64

    resetPoolState()
    discard setPagePoolEvictionPolicy(maxRetainedPages = 8, maxRetainedBytes = 24'i64)

    var byteCapped = initPageBuffer(16)
    byteCapped.add("abcdefghijklmnopqrstuvwxyz0123456789")
    byteCapped.release()

    metrics = pagePoolMetrics()
    check metrics.retainedPages == 1
    check metrics.retainedBytes == 16'i64

  test "explicit trim shrinks retained pool":
    resetPoolState()
    discard setPagePoolEvictionPolicy(maxRetainedPages = 8, maxRetainedBytes = 0'i64)

    var pooled = initPageBuffer(16)
    pooled.add("abcdefghijklmnopqrstuvwxyz0123456789")
    pooled.release()

    var metrics = pagePoolMetrics()
    check metrics.retainedPages >= 2

    let evicted = trimPagePool(retainPages = 1)
    check evicted >= 1
    metrics = pagePoolMetrics()
    check metrics.retainedPages == 1

    discard trimPagePool(retainPages = 0, retainBytes = 0'i64)
    metrics = pagePoolMetrics()
    check metrics.retainedPages == 0
    check metrics.retainedBytes == 0'i64
