## POD scratch-list helper for nim_simdjson hot paths.
## This is intentionally narrower than `seq`: it only supports copy-mem-safe
## element types and exposes explicit capacity reuse / uninitialized growth.

import std/typetraits

type
  FastListObj[T] = object
    len*: int
    cap*: int
    data: ptr UncheckedArray[T]

  FastList*[T] = ref FastListObj[T]

template requireFastListType(T: typedesc) =
  static:
    when not supportsCopyMem(T):
      {.error: "FastList requires supportsCopyMem(T) element types".}

proc `=destroy`[T](obj: FastListObj[T]) =
  if obj.data != nil:
    deallocShared(obj.data)

proc freeFastListStorage[T](list: FastList[T]) =
  requireFastListType(T)
  if list != nil and list.data != nil:
    deallocShared(list.data)
  list.data = nil
  list.len = 0
  list.cap = 0

## Create a new FastList with an optional initial capacity for POD element types.
proc newFastList*[T](initialCapacity = 0): FastList[T] =
  requireFastListType(T)
  if initialCapacity < 0:
    raise newException(ValueError, "initialCapacity must be >= 0")
  new(result)
  if initialCapacity > 0:
    let bytes = sizeof(T) * initialCapacity
    let raw = cast[ptr UncheckedArray[T]](allocShared(bytes))
    doAssert raw != nil, "fast list allocation failed"
    result.data = raw
    result.cap = initialCapacity

## Free the backing storage of ``list`` and reset its length and capacity.
proc close*[T](list: FastList[T]) {.inline.} =
  freeFastListStorage(list)

## Whether ``list`` is a nil fast list.
proc isNil*[T](list: FastList[T]): bool {.inline.} =
  list == nil

## Number of elements currently stored in ``list``.
proc len*[T](list: FastList[T]): int {.inline.} =
  if list == nil: 0 else: list.len

## Allocated element capacity of ``list``.
proc capacity*[T](list: FastList[T]): int {.inline.} =
  if list == nil: 0 else: list.cap

proc requireList[T](list: FastList[T]) {.inline.} =
  if list == nil:
    raise newException(ValueError, "fast list is nil")

## Grow the backing storage of ``list`` so it can hold at least ``needed`` elements.
proc reserve*[T](list: FastList[T], needed: int) =
  requireFastListType(T)
  list.requireList()
  if needed < 0:
    raise newException(ValueError, "reserve size must be >= 0")
  if needed <= list.cap:
    return
  let bytes = sizeof(T) * needed
  let raw =
    if list.data == nil:
      cast[ptr UncheckedArray[T]](allocShared(bytes))
    else:
      cast[ptr UncheckedArray[T]](reallocShared(list.data, bytes))
  doAssert raw != nil, "fast list allocation failed"
  list.data = raw
  list.cap = needed

proc nextCapacity(currentCap, needed: int): int {.inline.} =
  result = if currentCap > 0: currentCap else: 8
  while result < needed:
    if result < 1024:
      result *= 2
    else:
      result += result shr 1

## Grow ``list`` geometrically until it can hold ``neededLen`` elements.
proc ensureCapacityFor*[T](list: FastList[T], neededLen: int) {.inline.} =
  list.requireList()
  if neededLen > list.cap:
    list.reserve(nextCapacity(list.cap, neededLen))

## Reset the element count of ``list`` to zero, keeping its capacity.
proc clear*[T](list: FastList[T]) {.inline.} =
  if list != nil:
    list.len = 0

## Set the element count of ``list`` to ``newLen`` without initializing the new slots.
proc setLenUninit*[T](list: FastList[T], newLen: int) {.inline.} =
  requireFastListType(T)
  list.requireList()
  if newLen < 0:
    raise newException(ValueError, "newLen must be >= 0")
  list.ensureCapacityFor(newLen)
  list.len = newLen

## Append ``value`` to ``list``, growing capacity as needed.
proc add*[T](list: FastList[T], value: sink T) {.inline.} =
  requireFastListType(T)
  list.requireList()
  let idx = list.len
  list.ensureCapacityFor(idx + 1)
  list.data[idx] = value
  list.len = idx + 1

## Append ``value`` to ``list`` without a growth check; asserts capacity is sufficient.
proc addUnchecked*[T](list: FastList[T], value: sink T) {.inline.} =
  list.requireList()
  doAssert list.len < list.cap, "fast list capacity exceeded"
  let idx = list.len
  list.data[idx] = value
  list.len = idx + 1

## Remove and return the last element of ``list``; raises IndexDefect when empty.
proc pop*[T](list: FastList[T]): T =
  list.requireList()
  if list.len <= 0:
    raise newException(IndexDefect, "fast list is empty")
  dec list.len
  list.data[list.len]

## Expose the raw backing array of ``list`` for direct element access.
proc unsafeData*[T](list: FastList[T]): ptr UncheckedArray[T] {.inline.} =
  list.requireList()
  list.data

proc `[]`*[T](list: FastList[T], index: Natural): lent T {.inline.} =
  list.requireList()
  if index >= list.len:
    raise newException(IndexDefect, "fast list index out of bounds")
  list.data[index]

proc `[]=`*[T](list: FastList[T], index: Natural, value: sink T) {.inline.} =
  list.requireList()
  if index >= list.len:
    raise newException(IndexDefect, "fast list index out of bounds")
  list.data[index] = value

## Iterate over the elements of ``list`` in order.
iterator items*[T](list: FastList[T]): T =
  list.requireList()
  for i in 0 ..< list.len:
    yield list.data[i]

## Copy all elements of ``list`` into a new seq.
proc toSeq*[T](list: FastList[T]): seq[T] =
  list.requireList()
  result = newSeq[T](list.len)
  if list.len > 0:
    copyMem(addr result[0], addr list.data[0], sizeof(T) * list.len)
