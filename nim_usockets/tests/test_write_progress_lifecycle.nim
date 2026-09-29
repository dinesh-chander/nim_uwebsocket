import std/unittest

# Include internals to test response/write lifecycle helpers directly.
include ../src/nim_usockets/http

suite "Write progress lifecycle":
  test "fixed writes track payload offset and ignore header bytes":
    var resp = QueuedResponse(
      header: "HEAD",
      body: "abcdef",
      fileFd: -1,
      hasTryEnd: true,
      tryEndOffset: 0,
      tryEndTotal: 6
    )

    resp.applyFixedWriteProgress(2, 4)
    check resp.headerPos == 2
    check resp.bodyPos == 0
    check resp.tryEndOffset == 0'u64

    resp.applyFixedWriteProgress(5, 2)
    check resp.headerPos == 4
    check resp.bodyPos == 3
    check resp.tryEndOffset == 3'u64

    resp.applyFixedWriteProgress(10, 0)
    check resp.bodyPos == resp.body.len
    check resp.tryEndOffset == 6'u64

  test "coalescing stops at closeAfterWrite response boundary":
    var sockData = SocketData(
      pendingSlots: @[
        QueuedResponse(header: "H1", body: "B1", fileFd: -1),
        QueuedResponse(header: "H2", body: "B2", closeAfterWrite: true, fileFd: -1),
        QueuedResponse(header: "H3", body: "B3", fileFd: -1)
      ],
      pendingUsed: @[true, true, true],
      coalesceBuffer: ""
    )

    var scanEnd = 0
    let included = buildCoalescedWriteBuffer(addr sockData, 0, scanEnd)

    check included == 2
    check scanEnd == 2
    check sockData.coalesceBuffer == "H1B1H2B2"

  test "coalescing includes only the first response when it requires close":
    var sockData = SocketData(
      pendingSlots: @[
        QueuedResponse(header: "HX", body: "BX", closeAfterWrite: true, fileFd: -1),
        QueuedResponse(header: "HY", body: "BY", fileFd: -1)
      ],
      pendingUsed: @[true, true],
      coalesceBuffer: ""
    )

    var scanEnd = 0
    let included = buildCoalescedWriteBuffer(addr sockData, 0, scanEnd)

    check included == 1
    check scanEnd == 1
    check sockData.coalesceBuffer == "HXBX"
