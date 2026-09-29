import std/unittest

include ../src/nim_usockets/http

when not defined(nimUwebsocketsTest):
  {.error: "Compile this test with -d:nimUwebsocketsTest".}

when not defined(windows):
  proc addIov(iovecs: var seq[IOVec], part: var string) =
    iovecs.add(IOVec(
      iov_base: cast[pointer](addr part[0]),
      iov_len: csize_t(part.len)
    ))

  suite "writev batching hardening":
    test "writeSocketCheckedN batches vector count to runtime IOV_MAX":
      resetSocketFaultInjectionForTest()
      setMockWritevForTest(true)
      setWritevIovMaxForTest(3)

      var parts = @["a", "b", "c", "d", "e", "f", "g"]
      var iovecs: seq[IOVec] = @[]
      for idx in 0 ..< parts.len:
        addIov(iovecs, parts[idx])

      let fakeSocket = cast[UsSocketPtr](cast[pointer](0x1))
      let written = writeSocketCheckedN(0, fakeSocket, addr iovecs[0], iovecs.len, parts.len)
      let calls = writevCallsForTest()

      check written == parts.len
      check calls.len == 3
      check calls[0].iovcnt == 3
      check calls[0].totalLength == 3
      check calls[1].iovcnt == 3
      check calls[1].totalLength == 3
      check calls[2].iovcnt == 1
      check calls[2].totalLength == 1
      resetSocketFaultInjectionForTest()

    test "writeSocketCheckedN returns prior progress when a later batch stalls":
      resetSocketFaultInjectionForTest()
      setMockWritevForTest(true)
      setWritevIovMaxForTest(2)
      setInjectedWriteResultsForTest([2, 0])

      var parts = @["a", "b", "c", "d", "e"]
      var iovecs: seq[IOVec] = @[]
      for idx in 0 ..< parts.len:
        addIov(iovecs, parts[idx])

      let fakeSocket = cast[UsSocketPtr](cast[pointer](0x2))
      let written = writeSocketCheckedN(0, fakeSocket, addr iovecs[0], iovecs.len, parts.len)
      let calls = writevCallsForTest()

      check written == 2
      check calls.len == 2
      check calls[0].iovcnt == 2
      check calls[0].totalLength == 2
      check calls[1].iovcnt == 2
      check calls[1].totalLength == 2
      resetSocketFaultInjectionForTest()

    when sizeof(int) > sizeof(cint):
      test "writeSocketCheckedN splits batches at backend cint byte limit":
        resetSocketFaultInjectionForTest()
        setMockWritevForTest(true)

        let oversized = int(high(cint)) + 128
        var iov = IOVec(
          iov_base: cast[pointer](0x1000000),
          iov_len: csize_t(oversized)
        )

        let fakeSocket = cast[UsSocketPtr](cast[pointer](0x3))
        let written = writeSocketCheckedN(0, fakeSocket, addr iov, 1, oversized)
        let calls = writevCallsForTest()

        check written == oversized
        check calls.len == 2
        check calls[0].iovcnt == 1
        check calls[0].totalLength == int(high(cint))
        check calls[1].iovcnt == 1
        check calls[1].totalLength == 128
        resetSocketFaultInjectionForTest()
