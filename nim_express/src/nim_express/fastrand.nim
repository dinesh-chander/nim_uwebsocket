## Fast xorshift64* random number generator
## Much faster than Nim's stdlib random for hot paths

when defined(singleThread):
  var state*: uint64 = 0x853c49e6748fea9b'u64
else:
  var state* {.threadvar.}: uint64

proc ensureSeeded() {.inline.} =
  if state == 0:
    state = 0x853c49e6748fea9b'u64

## Set the internal generator state to the given seed, substituting a fixed fallback when the seed is zero.
proc seedFastRand*(seed: uint64) {.inline.} =
  state = seed
  if state == 0:
    state = 0x853c49e6748fea9b'u64

## Return the next value from the xorshift64* stream, seeding the internal state on first use.
proc fastRand*(): uint64 {.inline.} =
  ensureSeeded()
  state = state xor (state shr 12)
  state = state xor (state shl 25)
  state = state xor (state shr 27)
  return state * 0x2545F4914F6CDD1D'u64

## Return a fast pseudo-random integer from 0 up to but not including max; returns 0 when max is not positive.
proc fastRandRange*(max: int): int {.inline.} =
  ## Fast random in range [0, max)
  if max <= 0:
    return 0
  int(fastRand() mod uint64(max))

## Return a fast pseudo-random integer from min up to and including max; returns min when max is not above min.
proc fastRandRange*(min, max: int): int {.inline.} =
  ## Fast random in range [min, max]
  if max <= min:
    return min
  min + int(fastRand() mod uint64(max - min + 1))
