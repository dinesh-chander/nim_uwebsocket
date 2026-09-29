import std/unittest

include ../src/nim_usockets/http

suite "Sendfile resumable unification":
  test "queued sendfile responses are writable-continuation aware":
    let handler = proc(writeOffset: uint64): bool =
      writeOffset >= 0'u64

    let queued = initQueuedSendFileResponse(
      "HTTP/1.1 200 OK\r\ncontent-length: 4096\r\n\r\n",
      -1,
      4096,
      false,
      handler
    )

    check queued.isFileBody
    check queued.hasTryEnd
    check queued.tryEndOffset == 0'u64
    check queued.tryEndTotal == 4096'u64
    check queued.writableHandler != nil

  test "file-body resumable offset clamps to declared total":
    var queued = initQueuedSendFileResponse(
      "HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\n",
      -1,
      10,
      false,
      nil
    )

    queued.updateTryEndProgress(3)
    check queued.tryEndOffset == 3'u64

    queued.updateTryEndProgress(64)
    check queued.tryEndOffset == 10'u64

  test "pending writable handler update applies to sendfile resumable entries":
    let oldHandler = proc(writeOffset: uint64): bool =
      discard writeOffset
      false
    let newHandler = proc(writeOffset: uint64): bool =
      writeOffset == 7'u64

    var sockData: SocketData
    sockData.nextWriteSeq = 0'u64
    sockData.pendingStart = 0
    sockData.pendingSlots = @[
      initQueuedSendFileResponse(
        "HTTP/1.1 200 OK\r\ncontent-length: 9\r\n\r\n",
        -1,
        9,
        false,
        oldHandler
      )
    ]
    sockData.pendingUsed = @[true]

    updatePendingWritableHandler(addr sockData, 0'u64, newHandler)

    check sockData.pendingSlots[0].writableHandler != nil
    check sockData.pendingSlots[0].writableHandler(7'u64)
