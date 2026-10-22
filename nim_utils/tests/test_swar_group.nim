## Equivalence tests for the pure-Nim SWAR group-matching helpers in
## `helpers/swar_group.nim`: every mask must agree with a scalar byte loop
## over random and adversarial control arrays, including unaligned starts.

import std/[algorithm, bitops, random, unittest]

import ../src/nim_utils/helpers/swar_group

suite "swar_group SWAR helpers":
  test "swarHasZeroByte matches scalar reference exhaustively for adjacent pairs":
    # Exhaustive over (byte i, byte i+1) catches the borrow false-positive
    # class: a zero lane must never light the lane after it.
    for a in 0..255:
      for b in 0..255:
        var x = 0'u64
        x = x or uint64(a)
        x = x or (uint64(b) shl 8)
        # swarHasZeroByte emits the HIGH bit of each zero lane: bit 8k+7.
        let m = swarHasZeroByte(x)
        check ((m and 0x80) != 0) == (a == 0)
        check ((m and 0x8000) != 0) == (b == 0)

  test "swarHasZeroByte matches scalar reference on random words":
    var rng = initRand(20261019)
    for _ in 0..<20000:
      let x: uint64 = cast[uint64](rng.rand(0xFFFF_FFFF)) or
            (cast[uint64](rng.rand(0xFFFF_FFFF)) shl 32)
      var expect = 0'u64
      for i in 0..7:
        if ((x shr (8 * i)) and 0xFF) == 0:
          expect = expect or (0x80'u64 shl (8 * i))
      check swarHasZeroByte(x) == expect

  proc scalarMatch16(ctrl: pointer, h2: uint8): uint32 =
    let p = cast[ptr UncheckedArray[uint8]](ctrl)
    for i in 0..15:
      if p[i] == h2:
        result = result or (1'u32 shl i)

  test "swarMatch16 matches scalar reference on random ctrl groups":
    var rng = initRand(97531)
    # Ctrl bytes come from the Swiss-table alphabet: empty 0xFF, deleted 0x80,
    # occupied h2 with the high bit clear.
    for _ in 0..<20000:
      var buf: array[32, uint8]
      for i in 0..<16:
        case rng.rand(2)
        of 0: buf[i] = 0xFF
        of 1: buf[i] = 0x80
        else: buf[i] = uint8(rng.rand(0x7F))
      let h2: uint8 = uint8(rng.rand(0xFF))
      # Unaligned starts too: probes are not 8-byte aligned.
      for off in 0..1:
        let m = swarMatch16(addr buf[off], h2)
        check m == scalarMatch16(addr buf[off], h2)

  test "swarMatch16 borrow case: exact match followed by h2+1":
    # ctrl = [h2, h2+1]: only slot 0 matches; the subtract-based hasZero
    # variant reported slot 1 as well.
    for h2 in 0'u8 ..< 0x7F:
      var buf: array[16, uint8]
      buf[0] = h2
      buf[1] = h2 + 1
      for i in 2 ..< 16: buf[i] = 0xFF
      check swarMatch16(addr buf[0], h2) == 1'u32
      check swarMatch16(addr buf[0], h2 + 1) == 2'u32

  test "swarMatchEmpty16 and swarMatchEmptyOrDel16 match scalar reference":
    var rng = initRand(424242)
    for _ in 0..<20000:
      var buf: array[16, uint8]
      for i in 0..<16:
        case rng.rand(2)
        of 0: buf[i] = 0xFF
        of 1: buf[i] = 0x80
        else: buf[i] = uint8(rng.rand(0x7F))
      var expectEmpty, expectFree: uint32
      for i in 0..15:
        if buf[i] == 0xFF:
          expectEmpty = expectEmpty or (1'u32 shl i)
        if buf[i] == 0xFF or buf[i] == 0x80:
          expectFree = expectFree or (1'u32 shl i)
      check swarMatchEmpty16(addr buf[0]) == expectEmpty
      check swarMatchEmptyOrDel16(addr buf[0]) == expectFree

  test "portable SWAR path agrees with the active path":
    var rng = initRand(13579)
    for _ in 0..<20000:
      var buf: array[32, uint8]
      for i in 0..<16:
        case rng.rand(2)
        of 0: buf[i] = 0xFF
        of 1: buf[i] = 0x80
        else: buf[i] = uint8(rng.rand(0x7F))
      let h2: uint8 = uint8(rng.rand(0xFF))
      for off in 0..1:
        check swarMatch16Portable(addr buf[off], h2) == swarMatch16(addr buf[off], h2)
        check swarMatchEmpty16Portable(addr buf[off]) == swarMatchEmpty16(addr buf[off])
        check swarMatchEmptyOrDel16Portable(addr buf[off]) == swarMatchEmptyOrDel16(addr buf[off])

  test "swarFirstSlot and swarClearLowest iterate set bits in order":
    var rng = initRand(777)
    for _ in 0..<20000:
      var m: uint32 = cast[uint32](rng.rand(0xFFFF_FFFF))
      if m == 0: continue
      var seen: seq[int] = @[]
      while m != 0:
        let i = swarFirstSlot(m)
        check (0 <= i) and (i < 32)
        check (m and (1'u32 shl i)) != 0
        seen.add(i)
        m = swarClearLowest(m)
      check seen == seen.sorted()
      for i in 0 ..< seen.high:
        check seen[i] < seen[i + 1]
