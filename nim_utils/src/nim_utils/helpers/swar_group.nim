## Pure-Nim SWAR group matching for the Swiss-table style control arrays
## used by `fast_map` and `fast_set`.
## A 16-slot group is matched with one 16-byte compare on x86/x86_64
## (SSE2, via a one-line `{.emit.}` builtin) and with two 64-bit SWAR loads
## elsewhere; results are byte masks where bit i is set when slot i matches.

import std/bitops

const
  swarUseSimd* = (defined(i386) or defined(amd64)) and not defined(js) and
    not defined(nimSwarPortable) and
    (defined(gcc) or defined(clang)) and not defined(vcc)
    ## True when the SSE2 group-match path is compiled in; define
    ## `nimSwarPortable` to force the portable uint64 SWAR path.
  swarHiBit = 0x8080808080808080'u64   ## High bit set in every byte lane.
  swarLoOne = 0x0101010101010101'u64   ## One set in every byte lane.
  swarLo32 = 0xFFFF_FFFF'u64           ## Low 32 bits set.
  # Gather constant: for s whose bits are set only at 0, 8, 16, 24, the low
  # 4 bits of (cast[uint64](s and swarLo32) * swarGatherLo) shr 31 are s's
  # bits 0, 8, 16, 24 packed to 0..3 (each product term lands on a distinct
  # bit, so no carries disturb the read window).
  swarGatherLo = 0x81020400'u64

when swarUseSimd:
  # SSE2 group matching via nimsimd `_mm_*` intrinsics (cross-compiler: works
  # under both gcc and clang/LLVM, unlike the previous GCC-only
  # `__builtin_ia32_*` emits). One unaligned 16-byte load + per-byte compare +
  # movemask yields the 16-bit slot mask directly.
  import nimsimd/sse2

  proc cSwarMatch16(p: pointer; h2: cuint): cuint {.inline.} =
    let v = mm_loadu_si128(p)
    let k = mm_set1_epi8(h2.uint8)
    cuint(mm_movemask_epi8(mm_cmpeq_epi8(v, k)))

  proc cSwarMatchEmpty16(p: pointer): cuint {.inline.} =
    let v = mm_loadu_si128(p)
    let k = mm_set1_epi8(0xFF'u8)
    cuint(mm_movemask_epi8(mm_cmpeq_epi8(v, k)))

  proc cSwarMatchEmptyOrDel16(p: pointer): cuint {.inline.} =
    let v = mm_loadu_si128(p)
    cuint(mm_movemask_epi8(v))

## Set the high bit of lane i in the result iff byte i of `x` is zero.
## Exact per-lane (absl form): the (x and lo7) + 0x7F sum never carries
## (0x7F + 0x7F < 0x100), so each lane is independent; a nonzero byte always
## raises the sum lane or x lane high bit, which the final `not` clears.
## Do NOT use (x - 1) & ~x & 0x80 here: a zero byte borrows from the next
## lane and produces a false positive when the next byte is 1.
proc swarHasZeroByte*(x: uint64): uint64 {.inline.} =
  not (((x and 0x7F7F7F7F7F7F7F7F'u64) + 0x7F7F7F7F7F7F7F7F'u64) or x or 0x7F7F7F7F7F7F7F7F'u64)

## Pack the eight lane high bits of `x` into bits 0..7 of a byte mask: bit k
## of the result is bit 8k+7 of `x`.
proc swarPackHiBits(x: uint64): uint32 {.inline.} =
  # After shr 7 the lane high bits sit at positions 0, 8, ..., 56; gather
  # each 32-bit half into its own low nibble, then combine.
  let s = (x and swarHiBit) shr 7
  # Mask off the 4 read bits: off-diagonal product terms land above bit 34.
  let lo = (((s and swarLo32) * swarGatherLo) shr 31) and 0xF'u64
  let hi = ((((s shr 32) and swarLo32) * swarGatherLo) shr 31) and 0xF'u64
  result = (lo or (hi shl 4)).uint32

## Build the 16-bit byte mask of slots in the group at `ctrl` whose control
## byte equals `h2`. `ctrl` must point at 16 readable bytes; group starts are
## not 8-byte aligned, so loads are unaligned by construction.
proc swarMatch16Portable*(ctrl: pointer, h2: uint8): uint32 {.inline.} =
  let p = cast[ptr UncheckedArray[uint8]](ctrl)
  var w0, w1: uint64
  copyMem(addr w0, addr p[0], 8)
  copyMem(addr w1, addr p[8], 8)
  let b = swarLoOne * uint64(h2)
  let lo = swarPackHiBits(swarHasZeroByte(w0 xor b))
  let hi = swarPackHiBits(swarHasZeroByte(w1 xor b))
  result = lo or (hi shl 8)

## Byte mask of empty slots (control byte 0xFF) in the group at `ctrl`;
## portable two-load variant.
proc swarMatchEmpty16Portable*(ctrl: pointer): uint32 {.inline.} =
  swarMatch16Portable(ctrl, 0xFF'u8)

## Byte mask of free slots (empty or deleted) in the group at `ctrl`; the
## high bit marks both states, so no arithmetic is needed. Portable variant.
proc swarMatchEmptyOrDel16Portable*(ctrl: pointer): uint32 {.inline.} =
  let p = cast[ptr UncheckedArray[uint8]](ctrl)
  var w0, w1: uint64
  copyMem(addr w0, addr p[0], 8)
  copyMem(addr w1, addr p[8], 8)
  let lo = swarPackHiBits(w0)
  let hi = swarPackHiBits(w1)
  result = lo or (hi shl 8)

## Byte mask of slots in the group at `ctrl` whose control byte equals `h2`.
proc swarMatch16*(ctrl: pointer, h2: uint8): uint32 {.inline.} =
  when swarUseSimd:
    cSwarMatch16(ctrl, h2.uint32).uint32
  else:
    swarMatch16Portable(ctrl, h2)

## Byte mask of empty slots (control byte 0xFF) in the group at `ctrl`.
## Occupied control bytes always have the high bit clear, so they can never
## match 0xFF or a tombstone (0x80).
proc swarMatchEmpty16*(ctrl: pointer): uint32 {.inline.} =
  when swarUseSimd:
    cSwarMatchEmpty16(ctrl).uint32
  else:
    swarMatchEmpty16Portable(ctrl)

## Byte mask of free slots (empty or deleted) in the group at `ctrl`; the
## high bit of each control byte marks both states.
proc swarMatchEmptyOrDel16*(ctrl: pointer): uint32 {.inline.} =
  when swarUseSimd:
    cSwarMatchEmptyOrDel16(ctrl).uint32
  else:
    swarMatchEmptyOrDel16Portable(ctrl)

## Index of the lowest set bit in a byte mask; callers must guard `m` nonzero.
proc swarFirstSlot*(m: uint32): int {.inline.} =
  countTrailingZeroBits(m)

## Clear the lowest set bit of a byte mask; callers must guard `m` nonzero.
proc swarClearLowest*(m: uint32): uint32 {.inline.} =
  m and (m - 1)
