## Correctness tests for the nimsimd-backed `simd_str` string primitive and
## its wiring into `fast_map` / `fast_set`. The SSE2 and portable paths must
## both agree with an independent scalar byte-loop reference across edge-case
## lengths, random contents, and single-byte perturbations; the integration
## tests confirm the maps/sets still behave correctly with long keys routed
## through the SIMD comparison.

import std/[random, sequtils, strutils]
import std/unittest

import ../src/nim_utils/helpers/simd_str
import ../src/nim_utils/helpers/fast_map
import ../src/nim_utils/helpers/fast_set

## Independent reference: pure scalar byte loop (does not use equalMem or
## any SIMD/SWAR helper) so it cannot share a bug with the implementation.
proc refEquals(a, b: pointer, n: int): bool =
  if n <= 0:
    return true
  let pa = cast[ptr UncheckedArray[uint8]](a)
  let pb = cast[ptr UncheckedArray[uint8]](b)
  for i in 0..<n:
    if pa[i] != pb[i]:
      return false
  true

suite "simd_str primitives":
  test "edge-case lengths: empty and boundaries agree with reference":
    let s = "0123456789abcdef0123456789abcdef0123456789"
    for n in @[0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 23, 24, 31, 32, 33, 40, 41, 64, 100]:
      if n > s.len: continue
      check simdStrEquals(addr s[0], addr s[0], n) == refEquals(addr s[0], addr s[0], n)
      check simdStrEqualsPortable(addr s[0], addr s[0], n) == refEquals(addr s[0], addr s[0], n)

  test "single-byte perturbation detected at every position":
    let base = "abcdefghijklmnopqrstuvwxyz0123456789"
    let n = base.len
    var a = base
    var b = base
    for pos in 0..<n:
      a[pos] = if a[pos] == 'z': 'a' else: chr(ord(a[pos]) + 1)
      b = base
      check simdStrEquals(addr a[0], addr b[0], n) == false
      check simdStrEqualsPortable(addr a[0], addr b[0], n) == false
      a = base

  test "random contents: SSE2, portable, and scalar all agree":
    var rng = initRand(20261027)
    let lengths = @[0, 1, 5, 7, 8, 13, 15, 16, 17, 24, 31, 32, 33, 48, 100, 255, 1000, 4097]
    for n in lengths:
      if n == 0:
        let z: uint8 = 0
        check simdStrEquals(addr z, addr z, 0)
        check simdStrEqualsPortable(addr z, addr z, 0)
        continue
      for _ in 0..<400:
        var sa = newSeq[uint8](n)
        var sb = newSeq[uint8](n)
        for i in 0..<n:
          sa[i] = uint8(rng.rand(255))
          sb[i] = uint8(rng.rand(255))
        # ~half the time force a match, ~half a single-byte difference.
        if rng.rand(1) == 0:
          sb = sa
        else:
          let pos = rng.rand(n - 1)
          var v = uint8(rng.rand(255))
          if v == sa[pos]: v = (v + 1).uint8
          sb[pos] = v
        let expect = refEquals(addr sa[0], addr sb[0], n)
        check simdStrEquals(addr sa[0], addr sb[0], n) == expect
        check simdStrEqualsPortable(addr sa[0], addr sb[0], n) == expect
        check simdStrEquals(addr sa[0], addr sb[0], n) == simdStrEqualsPortable(addr sa[0], addr sb[0], n)

  test "SSE2 path is compiled in on this platform or intentionally portable":
    # The gate must be self-consistent: whichever path is active, it matches
    # the reference. We do not hard-assert which path is active so the test
    # also passes on non-x86 builds.
    let s = "hello world, this is a simd equality check"
    var diff = s
    diff[0] = 'X'
    check simdStrEquals(addr s[0], addr s[0], s.len)
    check not simdStrEquals(addr s[0], addr diff[0], s.len)

suite "fast_map / fast_set via SIMD compare":
  test "FastMap long-key put/get/contains/excl":
    let m = newFastMap[string]()
    let longKeys = toSeq(0..<50).mapIt("key-" & $it & "-".repeat(64) & "-payload")
    for i, k in longKeys:
      check m.put(k, "value-" & $i)
    for i, k in longKeys:
      var got: string
      check m.tryGet(k, got)
      check got == "value-" & $i
      check m.contains(k)
    # A key differing only in the deep payload region must be absent.
    let missing = "key-0-" & "a".repeat(32) & "X" & "a".repeat(31) & "-payload"
    check not m.contains(missing)
    # Overwrite an existing long key.
    check m.put(longKeys[3], "replaced")
    var got: string
    check m.tryGet(longKeys[3], got) and got == "replaced"
    # Delete a long key.
    check m.del(longKeys[10])
    check not m.contains(longKeys[10])
    check m.len == longKeys.len - 1
    m.close()

  test "FastSet long-key incl/contains/excl":
    let s = newFastSet()
    let longKeys = toSeq(0..<50).mapIt("set-" & $it & "-".repeat(128) & "-tail")
    for k in longKeys:
      check not s.containsOrIncl(k)   # first insert -> was missing
      check s.contains(k)
    for k in longKeys:
      check s.containsOrIncl(k)       # already present
    check s.len == longKeys.len
    let missing = "set-5-" & "b".repeat(64) & "Z" & "b".repeat(63) & "-tail"
    check not s.contains(missing)
    check s.excl(longKeys[7])
    check not s.contains(longKeys[7])
    check s.len == longKeys.len - 1
    s.close()
