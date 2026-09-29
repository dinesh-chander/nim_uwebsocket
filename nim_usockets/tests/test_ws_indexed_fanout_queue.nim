import std/unittest
import ../src/nim_usockets/http

suite "WebSocket indexed fanout queueing":
  test "preserves FIFO order across partial drains":
    let q = newWsQueueDebug()
    check enqueueWsQueueDebug(q, "abcdef") == 6
    check enqueueWsQueueDebug(q, "XYZ") == 3

    var snap = snapshotWsQueueDebug(q)
    check snap.queueDepth == 2
    check snap.pendingBytes == 9
    check snap.headRemaining == "abcdef"

    check consumeWsQueueDebug(q, 2) == 2
    snap = snapshotWsQueueDebug(q)
    check snap.queueDepth == 2
    check snap.pendingBytes == 7
    check snap.headRemaining == "cdef"

    check consumeWsQueueDebug(q, 4) == 4
    snap = snapshotWsQueueDebug(q)
    check snap.queueDepth == 1
    check snap.pendingBytes == 3
    check snap.headRemaining == "XYZ"

    check consumeWsQueueDebug(q, 3) == 3
    snap = snapshotWsQueueDebug(q)
    check snap.queueDepth == 0
    check snap.pendingBytes == 0
    check snap.headRemaining.len == 0

  test "supports offset queueing without tail copy semantics":
    let q = newWsQueueDebug()
    check enqueueWsQueueDebug(q, "payload", 3) == 4

    var snap = snapshotWsQueueDebug(q)
    check snap.queueDepth == 1
    check snap.pendingBytes == 4
    check snap.headOffset == 3
    check snap.headRemaining == "load"

    check consumeWsQueueDebug(q, 2) == 2
    snap = snapshotWsQueueDebug(q)
    check snap.pendingBytes == 2
    check snap.headRemaining == "ad"

    check consumeWsQueueDebug(q, 2) == 2
    snap = snapshotWsQueueDebug(q)
    check snap.queueDepth == 0
    check snap.pendingBytes == 0

  test "reuses freed palette slots while queue remains active":
    let q = newWsQueueDebug()
    check enqueueWsQueueDebug(q, "AAAA") == 4
    check enqueueWsQueueDebug(q, "BBBB") == 4
    check consumeWsQueueDebug(q, 4) == 4

    var snap = snapshotWsQueueDebug(q)
    check snap.queueDepth == 1
    check snap.pendingBytes == 4
    check snap.paletteSlots == 2
    check snap.paletteFree == 1
    check snap.headRemaining == "BBBB"

    check enqueueWsQueueDebug(q, "CCCC") == 4
    snap = snapshotWsQueueDebug(q)
    check snap.queueDepth == 2
    check snap.pendingBytes == 8
    check snap.paletteSlots == 2
    check snap.paletteFree == 0
    check snap.headRemaining == "BBBB"

    compactWsQueueDebug(q)
    check consumeWsQueueDebug(q, 4) == 4
    snap = snapshotWsQueueDebug(q)
    check snap.queueDepth == 1
    check snap.pendingBytes == 4
    check snap.headRemaining == "CCCC"
