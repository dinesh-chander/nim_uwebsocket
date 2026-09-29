import std/[formatfloat, math, options, streams]
import macros
import ./simdjson/simdjson_ffi

type
  JsonKind* = enum
    jkNull
    jkBool
    jkInt64
    jkUint64
    jkDouble
    jkString
    jkArray
    jkObject

  SimdjsonError* = object of CatchableError
    code*: uint32

  StorageOwnerObj = object of RootObj

  StorageOwner = ref StorageOwnerObj

  DocStorageObj = object of StorageOwnerObj
    raw: ptr CDoc

  DocStorage = ref DocStorageObj

  NativeValueStorageObj = object of StorageOwnerObj
    root: CNativeValue

  NativeValueStorage = ref NativeValueStorageObj

  CopiedStringStorageObj = object of StorageOwnerObj
    owned: string

  CopiedStringStorage = ref CopiedStringStorageObj

  Document* = object
    storage: DocStorage

  Value* = object
    valid: bool
    storage: DocStorage
    handle: CValueHandle

  BorrowedString* = object
    storage: StorageOwner
    data: cstring
    size: int

  ProjectedField* = object
    key*: string
    present*: bool
    kind*: JsonKind
    stringValue*: BorrowedString
    boolValue*: bool
    int64Value*: int64
    uint64Value*: uint64
    float64Value*: float64
    storage: DocStorage
    childHandle: CValueHandle
    hasChild: bool

  ObjectCursor* = object
    storage: DocStorage
    handle: CValueHandle

  ArrayCursor* = object
    storage: DocStorage
    handle: CValueHandle

proc `=destroy`(storage: var DocStorageObj) =
  if storage.raw != nil:
    simdjsonDocFree(storage.raw)
    storage.raw = nil

proc `=destroy`(storage: var NativeValueStorageObj) =
  simdjsonNativeValueRelease(addr storage.root)

when defined(singleThread):
  var projectScratch: seq[CProjectEntry]
else:
  var projectScratch {.threadvar.}: seq[CProjectEntry]

proc errorString(code: uint32): string {.inline.} =
  $simdjsonErrorMessage(code)

proc raiseError(code: uint32): ref SimdjsonError {.inline.} =
  result = newException(SimdjsonError, errorString(code))
  result.code = code

proc ensureSuccess(code: uint32) {.inline.} =
  if code != simdjsonSuccessCode():
    raise raiseError(code)

proc csizeToInt(value: csize_t; what: string): int {.inline.} =
  if value > csize_t(high(int)):
    raise newException(ValueError, what & " is too large")
  int(value)

proc copyCString(data: cstring, len: csize_t): string {.inline.} =
  if data == nil or len == 0:
    return ""
  let n = csizeToInt(len, "simdjson string")
  result = newStringUninit(n)
  copyMem(addr result[0], data, n)

## Returns true if ``value`` is nil, meaning it is not bound to a parsed document.
proc isNil*(value: Value): bool {.inline.} =
  (not value.valid) or value.storage == nil or value.storage.raw == nil

## Returns true if ``value`` is bound to a parsed document.
proc isValid*(value: Value): bool {.inline.} =
  not value.isNil

proc `==`*(value: Value, nilValue: typeof(nil)): bool {.inline.} =
  discard nilValue
  value.isNil

proc `==`*(nilValue: typeof(nil), value: Value): bool {.inline.} =
  discard nilValue
  value.isNil

proc requireStorage(value: Value): DocStorage {.inline.} =
  if value.isNil:
    raise newException(ValueError, "value is nil")
  value.storage

proc requireStorage(doc: Document): DocStorage {.inline.} =
  if doc.storage == nil or doc.storage.raw == nil:
    raise newException(ValueError, "document is nil")
  doc.storage

proc requireStorage(cursor: ObjectCursor): DocStorage {.inline.} =
  if cursor.storage == nil or cursor.storage.raw == nil:
    raise newException(ValueError, "cursor is nil")
  cursor.storage

proc requireStorage(cursor: ArrayCursor): DocStorage {.inline.} =
  if cursor.storage == nil or cursor.storage.raw == nil:
    raise newException(ValueError, "cursor is nil")
  cursor.storage

proc requireDoc(value: Value): ptr CDoc {.inline.} = value.requireStorage().raw
proc requireDoc(cursor: ObjectCursor): ptr CDoc {.inline.} = cursor.requireStorage().raw
proc requireDoc(cursor: ArrayCursor): ptr CDoc {.inline.} = cursor.requireStorage().raw

proc newValue(storage: DocStorage, handle: CValueHandle): Value {.inline.} =
  result.valid = true
  result.storage = storage
  result.handle = handle

proc newObjectCursor(storage: DocStorage, handle: CValueHandle): ObjectCursor {.inline.} =
  result.storage = storage
  result.handle = handle

proc newArrayCursor(storage: DocStorage, handle: CValueHandle): ArrayCursor {.inline.} =
  result.storage = storage
  result.handle = handle

proc collectArrayHandles(cursor: ArrayCursor): seq[CValueHandle] =
  var rawLen: csize_t
  ensureSuccess(simdjsonValueLen(cursor.requireDoc(), cursor.handle, addr rawLen))
  let itemsLen = csizeToInt(rawLen, "simdjson array")
  result = newSeq[CValueHandle](itemsLen)
  if itemsLen == 0:
    return
  ensureSuccess(simdjsonValueGetArrayChildren(
    cursor.requireDoc(),
    cursor.handle,
    addr result[0],
    csize_t(itemsLen)
  ))

proc kindFromInt(rawKind: cint): JsonKind {.inline.} =
  case rawKind
  of 0: jkNull
  of 1: jkBool
  of 2: jkInt64
  of 3: jkUint64
  of 4: jkDouble
  of 5: jkString
  of 6: jkArray
  of 7: jkObject
  else:
    raise newException(ValueError, "unknown simdjson kind")

proc isMissingCode(code: uint32): bool {.inline.} =
  code == simdjsonNoSuchFieldCode() or code == simdjsonIndexOutOfBoundsCode()

proc borrowString(storage: StorageOwner, data: cstring, len: csize_t): BorrowedString {.inline.} =
  result.storage = storage
  result.data = data
  result.size = csizeToInt(len, "simdjson string")

proc newNativeValueStorage(root: sink CNativeValue): NativeValueStorage {.inline.} =
  new(result)
  result.root = root

proc ensureObject(storage: DocStorage, handle: CValueHandle): ObjectCursor =
  var rawKind: cint
  ensureSuccess(simdjsonValueKind(storage.raw, handle, addr rawKind))
  if kindFromInt(rawKind) != jkObject:
    raise raiseError(simdjsonIncorrectTypeCode())
  newObjectCursor(storage, handle)

proc ensureArray(storage: DocStorage, handle: CValueHandle): ArrayCursor =
  var rawKind: cint
  ensureSuccess(simdjsonValueKind(storage.raw, handle, addr rawKind))
  if kindFromInt(rawKind) != jkArray:
    raise raiseError(simdjsonIncorrectTypeCode())
  newArrayCursor(storage, handle)

proc ensureExists(storage: DocStorage, code: uint32, handle: CValueHandle): Value =
  ensureSuccess(code)
  newValue(storage, handle)

## Parses ``json`` into a simdjson-backed ``Document``, raising ``SimdjsonError`` if the input is not valid JSON.
proc parse*(json: string): Document =
  var raw: ptr CDoc
  ensureSuccess(simdjsonParse(json.cstring, json.len.csize_t, addr raw))
  new(result.storage)
  result.storage.raw = raw

## Returns the root ``Value`` of ``doc``.
proc root*(doc: Document): Value =
  let storage = doc.requireStorage()
  var handle: CValueHandle
  ensureSuccess(simdjsonDocRoot(storage.raw, addr handle))
  newValue(storage, handle)

## Returns the root of ``doc`` as an ``ObjectCursor``, raising if the root is not an object.
proc rootCursor*(doc: Document): ObjectCursor =
  let storage = doc.requireStorage()
  var handle: CValueHandle
  ensureSuccess(simdjsonDocRoot(storage.raw, addr handle))
  ensureObject(storage, handle)

## Returns the root of ``doc`` as an ``ArrayCursor``, raising if the root is not an array.
proc rootArrayCursor*(doc: Document): ArrayCursor =
  let storage = doc.requireStorage()
  var handle: CValueHandle
  ensureSuccess(simdjsonDocRoot(storage.raw, addr handle))
  ensureArray(storage, handle)

## Returns the ``JsonKind`` of ``value``.
proc kind*(value: Value): JsonKind =
  var rawKind: cint
  ensureSuccess(simdjsonValueKind(value.requireDoc(), value.handle, addr rawKind))
  kindFromInt(rawKind)

## Returns the element count of the array or object ``value``.
proc len*(value: Value): int =
  var outLen: csize_t
  ensureSuccess(simdjsonValueLen(value.requireDoc(), value.handle, addr outLen))
  csizeToInt(outLen, "simdjson value")

## Returns the number of elements in the array.
proc len*(cursor: ArrayCursor): int =
  var outLen: csize_t
  ensureSuccess(simdjsonValueLen(cursor.requireDoc(), cursor.handle, addr outLen))
  csizeToInt(outLen, "simdjson array")

## Returns the number of keys in the object.
proc len*(cursor: ObjectCursor): int =
  var outLen: csize_t
  ensureSuccess(simdjsonValueLen(cursor.requireDoc(), cursor.handle, addr outLen))
  csizeToInt(outLen, "simdjson object")

## Returns the string content of ``value`` as a ``BorrowedString``.
proc getStrView*(value: Value): BorrowedString =
  var rawData: cstring
  var rawLen: csize_t
  ensureSuccess(simdjsonValueGetString(value.requireDoc(), value.handle, addr rawData, addr rawLen))
  borrowString(value.requireStorage(), rawData, rawLen)

## Returns the string content of ``value`` as an owned string.
proc getStr*(value: Value): string =
  let view = value.getStrView()
  copyCString(view.data, view.size.csize_t)

## Returns the boolean content of ``value``.
proc getBool*(value: Value): bool =
  var outValue = false
  ensureSuccess(simdjsonValueGetBool(value.requireDoc(), value.handle, addr outValue))
  outValue

## Returns the signed 64-bit integer content of ``value``.
proc getInt64*(value: Value): int64 =
  var outValue: int64
  ensureSuccess(simdjsonValueGetInt64(value.requireDoc(), value.handle, addr outValue))
  outValue

## Returns the unsigned 64-bit integer content of ``value``.
proc getUint64*(value: Value): uint64 =
  var outValue: uint64
  ensureSuccess(simdjsonValueGetUint64(value.requireDoc(), value.handle, addr outValue))
  outValue

## Returns the floating point content of ``value``.
proc getFloat64*(value: Value): float64 =
  var outValue: cdouble
  ensureSuccess(simdjsonValueGetDouble(value.requireDoc(), value.handle, addr outValue))
  float64(outValue)

## Returns true if the object ``value`` contains the key ``key``.
proc hasKey*(value: Value, key: string): bool =
  var present = false
  ensureSuccess(simdjsonValueContainsKey(value.requireDoc(), value.handle, key.cstring, key.len.csize_t, addr present))
  present

## Returns true if the object ``cursor`` contains the key ``key``.
proc hasKey*(cursor: ObjectCursor, key: string): bool =
  var present = false
  ensureSuccess(simdjsonValueContainsKey(cursor.requireDoc(), cursor.handle, key.cstring, key.len.csize_t, addr present))
  present

## Looks up ``key`` in ``value``, writes its ``JsonKind`` to ``outKind``, and returns false if missing.
proc tryKeyKind*(value: Value, key: string, outKind: var JsonKind): bool =
  var rawKind: cint
  let code = simdjsonValueKeyKind(value.requireDoc(), value.handle, key.cstring, key.len.csize_t, addr rawKind)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  outKind = kindFromInt(rawKind)
  true

## Looks up ``key`` in ``cursor``, writes its ``JsonKind`` to ``outKind``, and returns false if missing.
proc tryKeyKind*(cursor: ObjectCursor, key: string, outKind: var JsonKind): bool =
  var rawKind: cint
  let code = simdjsonValueKeyKind(cursor.requireDoc(), cursor.handle, key.cstring, key.len.csize_t, addr rawKind)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  outKind = kindFromInt(rawKind)
  true

## Fills ``outValue`` with the string at ``key`` in ``value``; returns false if missing or not a string.
proc tryGetStrView*(value: Value, key: string, outValue: var BorrowedString): bool =
  var rawData: cstring
  var rawLen: csize_t
  let code = simdjsonValueGetKeyString(value.requireDoc(), value.handle, key.cstring, key.len.csize_t, addr rawData, addr rawLen)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  outValue = borrowString(value.requireStorage(), rawData, rawLen)
  true

## Fills ``outValue`` with the string at ``key`` in ``cursor``; returns false if missing or not a string.
proc tryGetStrView*(cursor: ObjectCursor, key: string, outValue: var BorrowedString): bool =
  var rawData: cstring
  var rawLen: csize_t
  let code = simdjsonValueGetKeyString(cursor.requireDoc(), cursor.handle, key.cstring, key.len.csize_t, addr rawData, addr rawLen)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  outValue = borrowString(cursor.requireStorage(), rawData, rawLen)
  true

## Fills ``outValue`` with a copy of the string at ``key`` in ``value``; returns false if missing or not a string.
proc tryGetStr*(value: Value, key: string, outValue: var string): bool =
  var rawView: BorrowedString
  if not value.tryGetStrView(key, rawView):
    return false
  outValue = copyCString(rawView.data, rawView.size.csize_t)
  true

## Fills ``outValue`` with a copy of the string at ``key`` in ``cursor``; returns false if missing or not a string.
proc tryGetStr*(cursor: ObjectCursor, key: string, outValue: var string): bool =
  var rawView: BorrowedString
  if not cursor.tryGetStrView(key, rawView):
    return false
  outValue = copyCString(rawView.data, rawView.size.csize_t)
  true

## Fills ``outValue`` with the boolean at ``key`` in ``value``; returns false if missing or not a boolean.
proc tryGetBool*(value: Value, key: string, outValue: var bool): bool =
  let code = simdjsonValueGetKeyBool(value.requireDoc(), value.handle, key.cstring, key.len.csize_t, addr outValue)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  true

## Fills ``outValue`` with the boolean at ``key`` in ``cursor``; returns false if missing or not a boolean.
proc tryGetBool*(cursor: ObjectCursor, key: string, outValue: var bool): bool =
  let code = simdjsonValueGetKeyBool(cursor.requireDoc(), cursor.handle, key.cstring, key.len.csize_t, addr outValue)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  true

## Fills ``outValue`` with the signed 64-bit integer at ``key`` in ``value``; returns false if missing or wrong type.
proc tryGetInt64*(value: Value, key: string, outValue: var int64): bool =
  let code = simdjsonValueGetKeyInt64(value.requireDoc(), value.handle, key.cstring, key.len.csize_t, addr outValue)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  true

## Fills ``outValue`` with the signed 64-bit integer at ``key`` in ``cursor``; returns false if missing or wrong type.
proc tryGetInt64*(cursor: ObjectCursor, key: string, outValue: var int64): bool =
  let code = simdjsonValueGetKeyInt64(cursor.requireDoc(), cursor.handle, key.cstring, key.len.csize_t, addr outValue)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  true

## Fills ``outValue`` with the unsigned 64-bit integer at ``key`` in ``value``; returns false if missing or wrong type.
proc tryGetUint64*(value: Value, key: string, outValue: var uint64): bool =
  let code = simdjsonValueGetKeyUint64(value.requireDoc(), value.handle, key.cstring, key.len.csize_t, addr outValue)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  true

## Fills ``outValue`` with the unsigned 64-bit integer at ``key`` in ``cursor``; returns false if missing or wrong type.
proc tryGetUint64*(cursor: ObjectCursor, key: string, outValue: var uint64): bool =
  let code = simdjsonValueGetKeyUint64(cursor.requireDoc(), cursor.handle, key.cstring, key.len.csize_t, addr outValue)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  true

## Fills ``outValue`` with the object at ``key`` in ``value``; returns false if missing or not an object.
proc tryGetObjectCursor*(value: Value, key: string, outValue: var ObjectCursor): bool =
  let storage = value.requireStorage()
  var handle: CValueHandle
  let code = simdjsonValueGetKeyObject(storage.raw, value.handle, key.cstring, key.len.csize_t, addr handle)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  outValue = newObjectCursor(storage, handle)
  true

## Fills ``outValue`` with the object at ``key`` in ``cursor``; returns false if missing or not an object.
proc tryGetObjectCursor*(cursor: ObjectCursor, key: string, outValue: var ObjectCursor): bool =
  let storage = cursor.requireStorage()
  var handle: CValueHandle
  let code = simdjsonValueGetKeyObject(storage.raw, cursor.handle, key.cstring, key.len.csize_t, addr handle)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  outValue = newObjectCursor(storage, handle)
  true

## Fills ``outValue`` with the array at ``key`` in ``value``; returns false if missing or not an array.
proc tryGetArrayCursor*(value: Value, key: string, outValue: var ArrayCursor): bool =
  let storage = value.requireStorage()
  var handle: CValueHandle
  let code = simdjsonValueGetKeyArray(storage.raw, value.handle, key.cstring, key.len.csize_t, addr handle)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  outValue = newArrayCursor(storage, handle)
  true

## Fills ``outValue`` with the array at ``key`` in ``cursor``; returns false if missing or not an array.
proc tryGetArrayCursor*(cursor: ObjectCursor, key: string, outValue: var ArrayCursor): bool =
  let storage = cursor.requireStorage()
  var handle: CValueHandle
  let code = simdjsonValueGetKeyArray(storage.raw, cursor.handle, key.cstring, key.len.csize_t, addr handle)
  if isMissingCode(code):
    return false
  ensureSuccess(code)
  outValue = newArrayCursor(storage, handle)
  true

proc `[]`*(value: Value, key: string): Value =
  let storage = value.requireStorage()
  var handle: CValueHandle
  ensureExists(storage, simdjsonValueGetKey(storage.raw, value.handle, key.cstring, key.len.csize_t, addr handle), handle)

proc `[]`*(cursor: ObjectCursor, key: string): Value =
  let storage = cursor.requireStorage()
  var handle: CValueHandle
  ensureExists(storage, simdjsonValueGetKey(storage.raw, cursor.handle, key.cstring, key.len.csize_t, addr handle), handle)

proc `[]`*(value: Value, index: Natural): Value =
  let storage = value.requireStorage()
  var handle: CValueHandle
  ensureExists(storage, simdjsonValueGetIndex(storage.raw, value.handle, index.csize_t, addr handle), handle)

proc `[]`*(cursor: ArrayCursor, index: Natural): Value =
  let storage = cursor.requireStorage()
  var handle: CValueHandle
  ensureExists(storage, simdjsonValueGetIndex(storage.raw, cursor.handle, index.csize_t, addr handle), handle)

proc `[]`*(doc: Document, key: string): Value =
  doc.root()[key]

## Resolves the JSON pointer ``pointer`` against ``value`` and returns the referenced value.
proc atPointer*(value: Value, pointer: string): Value =
  let storage = value.requireStorage()
  var handle: CValueHandle
  ensureExists(
    storage,
    simdjsonValueAtPointer(storage.raw, value.handle, pointer.cstring, pointer.len.csize_t, addr handle),
    handle
  )

## Resolves the JSON pointer ``pointer`` against the root of ``doc`` and returns the referenced value.
proc atPointer*(doc: Document, pointer: string): Value =
  doc.root().atPointer(pointer)

## Returns the child at ``key`` of ``value``, or a nil value if the key is missing.
proc tryGet*(value: Value, key: string): Value =
  let storage = value.requireStorage()
  var handle: CValueHandle
  let code = simdjsonValueGetKey(storage.raw, value.handle, key.cstring, key.len.csize_t, addr handle)
  if isMissingCode(code):
    return Value()
  ensureExists(storage, code, handle)

## Returns the child at ``key`` of ``cursor``, or a nil value if the key is missing.
proc tryGet*(cursor: ObjectCursor, key: string): Value =
  let storage = cursor.requireStorage()
  var handle: CValueHandle
  let code = simdjsonValueGetKey(storage.raw, cursor.handle, key.cstring, key.len.csize_t, addr handle)
  if isMissingCode(code):
    return Value()
  ensureExists(storage, code, handle)

## Returns the child at ``key`` of the root of ``doc``, or a nil value if the key is missing.
proc tryGet*(doc: Document, key: string): Value =
  doc.root().tryGet(key)

## Looks up ``key`` at the root of ``doc``, writes its ``JsonKind`` to ``outKind``, and returns false if missing.
proc tryKeyKind*(doc: Document, key: string, outKind: var JsonKind): bool =
  doc.rootCursor().tryKeyKind(key, outKind)

## Fills ``outValue`` with the root string at ``key`` in ``doc``; returns false if missing or not a string.
proc tryGetStrView*(doc: Document, key: string, outValue: var BorrowedString): bool =
  doc.rootCursor().tryGetStrView(key, outValue)

## Fills ``outValue`` with a copy of the root string at ``key`` in ``doc``; returns false if missing or not a string.
proc tryGetStr*(doc: Document, key: string, outValue: var string): bool =
  doc.rootCursor().tryGetStr(key, outValue)

## Fills ``outValue`` with the root boolean at ``key`` in ``doc``; returns false if missing or not a boolean.
proc tryGetBool*(doc: Document, key: string, outValue: var bool): bool =
  doc.rootCursor().tryGetBool(key, outValue)

## Fills ``outValue`` with the root signed 64-bit integer at ``key`` in ``doc``; returns false if missing or wrong type.
proc tryGetInt64*(doc: Document, key: string, outValue: var int64): bool =
  doc.rootCursor().tryGetInt64(key, outValue)

## Fills ``outValue`` with the root unsigned 64-bit integer at ``key`` in ``doc``; returns false if missing or wrong type.
proc tryGetUint64*(doc: Document, key: string, outValue: var uint64): bool =
  doc.rootCursor().tryGetUint64(key, outValue)

## Fills ``outValue`` with the root object at ``key`` in ``doc``; returns false if missing or not an object.
proc tryGetObjectCursor*(doc: Document, key: string, outValue: var ObjectCursor): bool =
  doc.rootCursor().tryGetObjectCursor(key, outValue)

## Fills ``outValue`` with the root array at ``key`` in ``doc``; returns false if missing or not an array.
proc tryGetArrayCursor*(doc: Document, key: string, outValue: var ArrayCursor): bool =
  doc.rootCursor().tryGetArrayCursor(key, outValue)

## Resolves the JSON pointer ``pointer`` against ``value``; returns a nil value if the target is missing.
proc tryAtPointer*(value: Value, pointer: string): Value =
  let storage = value.requireStorage()
  var handle: CValueHandle
  let code = simdjsonValueAtPointer(storage.raw, value.handle, pointer.cstring, pointer.len.csize_t, addr handle)
  if isMissingCode(code):
    return Value()
  ensureExists(storage, code, handle)

## Resolves the JSON pointer ``pointer`` against the root of ``doc``; returns a nil value if the target is missing.
proc tryAtPointer*(doc: Document, pointer: string): Value =
  doc.root().tryAtPointer(pointer)

## Returns true if the JSON pointer ``pointer`` resolves to an existing value inside ``value``.
proc containsPointer*(value: Value, pointer: string): bool =
  value.tryAtPointer(pointer).isValid

## Returns true if the JSON pointer ``pointer`` resolves to an existing value inside ``doc``.
proc containsPointer*(doc: Document, pointer: string): bool =
  doc.tryAtPointer(pointer).isValid

## Returns true if ``value`` is a JSON null.
proc isNull*(value: Value): bool =
  value.kind == jkNull

## Wraps ``value`` as an ``ObjectCursor``; raises if ``value`` is not an object.
proc objectCursor*(value: Value): ObjectCursor =
  ensureObject(value.requireStorage(), value.handle)

## Wraps ``value`` as an ``ArrayCursor``; raises if ``value`` is not an array.
proc arrayCursor*(value: Value): ArrayCursor =
  ensureArray(value.requireStorage(), value.handle)

## Wraps the object child of the projected ``field`` as an ``ObjectCursor``; raises if unavailable.
proc objectCursor*(field: ProjectedField): ObjectCursor =
  if not field.present or field.kind != jkObject or not field.hasChild or field.storage == nil:
    raise raiseError(simdjsonIncorrectTypeCode())
  newObjectCursor(field.storage, field.childHandle)

## Wraps the array child of the projected ``field`` as an ``ArrayCursor``; raises if unavailable.
proc arrayCursor*(field: ProjectedField): ArrayCursor =
  if not field.present or field.kind != jkArray or not field.hasChild or field.storage == nil:
    raise raiseError(simdjsonIncorrectTypeCode())
  newArrayCursor(field.storage, field.childHandle)

## Fills ``outValue`` with the object child cursor of the projected ``field``; returns false if unavailable.
proc tryGetObjectCursor*(field: ProjectedField, outValue: var ObjectCursor): bool {.inline.} =
  if not field.present or field.kind != jkObject or not field.hasChild or field.storage == nil:
    return false
  outValue = newObjectCursor(field.storage, field.childHandle)
  true

## Fills ``outValue`` with the array child cursor of the projected ``field``; returns false if unavailable.
proc tryGetArrayCursor*(field: ProjectedField, outValue: var ArrayCursor): bool {.inline.} =
  if not field.present or field.kind != jkArray or not field.hasChild or field.storage == nil:
    return false
  outValue = newArrayCursor(field.storage, field.childHandle)
  true

## Wraps the object ``cursor`` as a ``Value``.
proc toValue*(cursor: ObjectCursor): Value =
  newValue(cursor.requireStorage(), cursor.handle)

## Wraps the array ``cursor`` as a ``Value``.
proc toValue*(cursor: ArrayCursor): Value =
  newValue(cursor.requireStorage(), cursor.handle)

proc clearProjectedField(field: var ProjectedField) {.inline.} =
  field.present = false
  field.kind = jkNull
  field.stringValue = BorrowedString()
  field.boolValue = false
  field.int64Value = 0
  field.uint64Value = 0
  field.float64Value = 0.0
  field.storage = nil
  field.childHandle = 0
  field.hasChild = false

## Reads the keys named in ``fields`` from the object ``cursor`` into the ``ProjectedField`` slots.
proc project*(cursor: ObjectCursor, fields: var openArray[ProjectedField]) =
  if fields.len == 0:
    return

  if projectScratch.len < fields.len:
    projectScratch.setLen(fields.len)
  for i in 0 ..< fields.len:
    fields[i].clearProjectedField()
    projectScratch[i] = CProjectEntry()
    projectScratch[i].key = fields[i].key.cstring
    projectScratch[i].key_len = fields[i].key.len.csize_t

  ensureSuccess(simdjsonValueProject(cursor.requireDoc(), cursor.handle, addr projectScratch[0], fields.len.csize_t))

  for i in 0 ..< fields.len:
    let raw = projectScratch[i]
    fields[i].present = raw.status == simdjsonSuccessCode()
    if isMissingCode(raw.status):
      continue
    ensureSuccess(raw.status)
    fields[i].kind = kindFromInt(raw.found_kind)
    case fields[i].kind
    of jkString:
      fields[i].stringValue = borrowString(cursor.storage, raw.str_data, raw.str_len)
    of jkBool:
      fields[i].boolValue = raw.bool_value
    of jkInt64:
      fields[i].int64Value = raw.int64_value
    of jkUint64:
      fields[i].uint64Value = raw.uint64_value
    of jkDouble:
      fields[i].float64Value = float64(raw.double_value)
    of jkArray, jkObject:
      fields[i].storage = cursor.storage
      fields[i].childHandle = raw.child_handle
      fields[i].hasChild = true
    of jkNull:
      discard

## Reads the keys named in ``fields`` from the object ``value`` into the ``ProjectedField`` slots.
proc project*(value: Value, fields: var openArray[ProjectedField]) =
  value.objectCursor().project(fields)

## Reads the keys named in ``fields`` from the root of ``doc`` into the ``ProjectedField`` slots.
proc project*(doc: Document, fields: var openArray[ProjectedField]) =
  doc.rootCursor().project(fields)

## Returns the byte length of ``value``.
proc len*(value: BorrowedString): int {.inline.} =
  value.size

## Returns true if ``value`` points at no data.
proc isNil*(value: BorrowedString): bool {.inline.} =
  value.data == nil

## Returns the raw data pointer of ``value``; the buffer is not NUL-terminated.
proc dataPtr*(value: BorrowedString): cstring {.inline.} =
  value.data

## Copies ``value`` into an owned string.
proc toString*(value: BorrowedString): string =
  copyCString(value.data, value.size.csize_t)

proc `$`*(value: BorrowedString): string =
  value.toString()

## Returns ``value`` with leading and trailing ASCII whitespace removed.
proc stripAscii*(value: BorrowedString): BorrowedString {.inline.} =
  result = value
  if result.data == nil or result.size == 0:
    return
  var start = 0
  var finish = result.size
  while start < finish and result.data[start] in {' ', '\t', '\r', '\n'}:
    inc start
  while finish > start and result.data[finish - 1] in {' ', '\t', '\r', '\n'}:
    dec finish
  result.data = cast[cstring](cast[uint](result.data) + uint(start))
  result.size = finish - start

## Returns true if ``value`` equals ``literal`` using a fast ASCII comparison.
proc equalsAscii*(value: BorrowedString, literal: string): bool {.inline.} =
  if value.size != literal.len:
    return false
  if value.data == nil:
    return literal.len == 0
  for i in 0 ..< literal.len:
    if value.data[i] != literal[i]:
      return false
  true

## Returns true if ``value`` equals ``literal`` ignoring case using a fast ASCII comparison.
proc equalsIgnoreCaseAscii*(value: BorrowedString, literal: string): bool {.inline.} =
  if value.size != literal.len:
    return false
  if value.data == nil:
    return literal.len == 0
  for i in 0 ..< literal.len:
    var left = value.data[i]
    var right = literal[i]
    if left in {'A' .. 'Z'}:
      left = chr(ord(left) + 32)
    if right in {'A' .. 'Z'}:
      right = chr(ord(right) + 32)
    if left != right:
      return false
  true

## Parses ``value`` as 1, 0, true, false, yes, no, on, or off into ``outValue``; returns false if unparseable.
proc parseBoolLikeAscii*(value: BorrowedString, outValue: var bool): bool {.inline.} =
  let trimmed = value.stripAscii()
  if trimmed.equalsAscii("1") or trimmed.equalsIgnoreCaseAscii("true") or
      trimmed.equalsIgnoreCaseAscii("yes") or trimmed.equalsIgnoreCaseAscii("on"):
    outValue = true
    return true
  if trimmed.equalsAscii("0") or trimmed.equalsIgnoreCaseAscii("false") or
      trimmed.equalsIgnoreCaseAscii("no") or trimmed.equalsIgnoreCaseAscii("off"):
    outValue = false
    return true
  false

## Returns true if ``json`` is syntactically valid JSON.
proc isValidJson*(json: string): bool {.inline.} =
  simdjsonIsValid(json.cstring, json.len.csize_t)

type
  SimdJsonCodec* = object

  JsonDocument* = Document
  JsonValue* = Value
  JsonObject* = ObjectCursor
  JsonArray* = ArrayCursor
  JsonStringView* = BorrowedString
  JsonCodec* = SimdJsonCodec
  JsonDecodeTier* = enum
    jdtUnsupported
    jdtDomFallback
    jdtOndemandLeaf
    jdtNativePlan
  JsonSchemaFieldKind* = enum
    jsfkUnsupported
    jsfkObject
    jsfkSeq
    jsfkArray
    jsfkOption
    jsfkRef
    jsfkString
    jsfkBorrowedString
    jsfkBool
    jsfkSignedInt
    jsfkUnsignedInt
    jsfkFloat
    jsfkChar
    jsfkEnum
  JsonSchemaFieldPlan* = object
    name*: string
    kind*: JsonSchemaFieldKind
    decodeTier*: JsonDecodeTier
    borrowedPreferred*: bool
    children*: seq[JsonSchemaFieldPlan]
  JsonSchemaPlan* = object
    tier*: JsonDecodeTier
    fields*: seq[JsonSchemaFieldPlan]
  JsonDirectFieldPlan* = object
    name*: string
    kind*: JsonSchemaFieldKind
    decodeTier*: JsonDecodeTier
    borrowedPreferred*: bool
    ordinal*: int
    nativeSubtreeSize*: int
    children*: seq[JsonDirectFieldPlan]
  JsonDirectDecodePlan* = object
    tier*: JsonDecodeTier
    fields*: seq[JsonDirectFieldPlan]

const
  cnpkUnsupported = 0.cint
  cnpkObject = 1.cint
  cnpkSeqObject = 2.cint
  cnpkString = 3.cint
  cnpkBool = 4.cint
  cnpkSignedInt = 5.cint
  cnpkUnsignedInt = 6.cint
  cnpkFloat = 7.cint

proc `==`*(left, right: BorrowedString): bool {.inline.} =
  if left.size != right.size:
    return false
  if left.size == 0:
    return true
  for i in 0 ..< left.size:
    if left.data[i] != right.data[i]:
      return false
  true

const HexDigits = "0123456789abcdef"

proc checkedJsonAdd(left, right: int; msg = "JSON output too large to serialize"): int {.inline.} =
  if left < 0 or right < 0 or left > high(int) - right:
    raise newException(ValueError, msg)
  left + right

proc checkedJsonMul(left, right: int; msg = "JSON output too large to serialize"): int {.inline.} =
  if left < 0 or right < 0 or (right != 0 and left > high(int) div right):
    raise newException(ValueError, msg)
  left * right

proc copyBytesToString(data: openArray[byte]): string {.inline.} =
  if data.len == 0:
    return ""
  result = newStringUninit(data.len)
  copyMem(addr result[0], unsafeAddr data[0], data.len)

proc copyStringToBytes(data: string): seq[byte] {.inline.} =
  if data.len == 0:
    return @[]
  result = newSeq[byte](data.len)
  copyMem(addr result[0], unsafeAddr data[0], data.len)

proc requireStream(stream: Stream) {.inline.} =
  if stream == nil:
    raise newException(ValueError, "stream is nil")

## Creates a new ``SimdJsonCodec``.
proc newSimdJsonCodec*(): SimdJsonCodec {.inline.} =
  SimdJsonCodec()

## Creates a new ``JsonCodec``.
proc newJsonCodec*(): JsonCodec {.inline.} =
  newSimdJsonCodec()

## Returns a fresh ``SimdJsonCodec``.
proc defaultCodec*(): SimdJsonCodec {.inline.} =
  newSimdJsonCodec()

## Returns a fresh ``JsonCodec``.
proc defaultJsonCodec*(): JsonCodec {.inline.} =
  newJsonCodec()

proc appendEscapedJsonBytes(buf: var string, data: cstring, dataLen: int) =
  var extra = 0
  for i in 0 ..< dataLen:
    let ch = data[i]
    case ch
    of '"', '\\', '\b', '\f', '\n', '\r', '\t':
      extra = checkedJsonAdd(extra, 1)
    else:
      if ord(ch) < 0x20:
        extra = checkedJsonAdd(extra, 5)

  let start = buf.len
  let total = checkedJsonAdd(checkedJsonAdd(dataLen, extra), 2)
  buf.setLen(checkedJsonAdd(start, total))
  buf[start] = '"'

  if extra == 0:
    if dataLen > 0:
      copyMem(addr buf[start + 1], data, dataLen)
    buf[start + total - 1] = '"'
    return

  var dst = start + 1
  for i in 0 ..< dataLen:
    let ch = data[i]
    case ch
    of '"':
      buf[dst] = '\\'
      buf[dst + 1] = '"'
      inc dst, 2
    of '\\':
      buf[dst] = '\\'
      buf[dst + 1] = '\\'
      inc dst, 2
    of '\b':
      buf[dst] = '\\'
      buf[dst + 1] = 'b'
      inc dst, 2
    of '\f':
      buf[dst] = '\\'
      buf[dst + 1] = 'f'
      inc dst, 2
    of '\n':
      buf[dst] = '\\'
      buf[dst + 1] = 'n'
      inc dst, 2
    of '\r':
      buf[dst] = '\\'
      buf[dst + 1] = 'r'
      inc dst, 2
    of '\t':
      buf[dst] = '\\'
      buf[dst + 1] = 't'
      inc dst, 2
    else:
      if ord(ch) < 0x20:
        buf[dst] = '\\'
        buf[dst + 1] = 'u'
        buf[dst + 2] = '0'
        buf[dst + 3] = '0'
        buf[dst + 4] = HexDigits[(ord(ch) shr 4) and 0xF]
        buf[dst + 5] = HexDigits[ord(ch) and 0xF]
        inc dst, 6
      else:
        buf[dst] = ch
        inc dst
  buf[start + total - 1] = '"'

proc appendEscapedJsonString(buf: var string, value: string) =
  if value.len == 0:
    buf.add("\"\"")
    return
  appendEscapedJsonBytes(buf, cast[cstring](unsafeAddr value[0]), value.len)

proc appendObjectKey(buf: var string, key: string) =
  buf.add('"')
  buf.add(key)
  buf.add("\":")

proc supportedObjectRecList(typeNode: NimNode): NimNode =
  var concrete = typeNode
  let typeInst = concrete.getTypeInst
  if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "typedesc"):
    concrete = typeInst[1]
  if concrete.kind != nnkSym:
    return newEmptyNode()
  let impl = concrete.getImpl
  if impl.kind == nnkTypeDef and impl.len >= 3:
    let objectTy = impl[2]
    if objectTy.kind == nnkObjectTy and objectTy.len >= 3 and objectTy[2].kind == nnkRecList:
      return objectTy[2]
  newEmptyNode()

proc unwrapTypedescNode(typeNode: NimNode): NimNode =
  let typeInst = typeNode.getTypeInst
  if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "typedesc"):
    typeInst[1]
  else:
    typeNode

proc isBorrowedStringTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  eqIdent(concrete, "BorrowedString") or eqIdent(concrete, "JsonStringView")

proc ondemandSupportedTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  if isBorrowedStringTypeNode(concrete):
    return true
  let typeInst = concrete.getTypeInst
  if typeInst.kind == nnkBracketExpr:
    if typeInst.len == 2 and (eqIdent(typeInst[0], "Option") or eqIdent(typeInst[0], "seq") or eqIdent(typeInst[0], "ref")):
      return ondemandSupportedTypeNode(typeInst[1])
    if typeInst.len == 3 and eqIdent(typeInst[0], "array"):
      return ondemandSupportedTypeNode(typeInst[2])

  let recList = supportedObjectRecList(concrete)
  if recList.kind == nnkRecList:
    for child in recList:
      if child.kind != nnkIdentDefs or child.len < 3:
        return false
      let fieldType = child[^2]
      if not ondemandSupportedTypeNode(fieldType):
        return false
    return true

  case concrete.typeKind
  of ntyString, ntyBool, ntyChar, ntyEnum,
     ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64,
     ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64,
     ntyFloat, ntyFloat32, ntyFloat64:
    true
  else:
    false

proc ondemandLeafTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  let typeInst = concrete.getTypeInst
  if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "Option"):
    return ondemandLeafTypeNode(typeInst[1])

  case concrete.typeKind
  of ntyString, ntyBool, ntyChar, ntyEnum,
     ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64,
     ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64,
     ntyFloat, ntyFloat32, ntyFloat64:
    true
  else:
    false

proc ondemandPreferredTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  if ondemandLeafTypeNode(concrete):
    return true

  let recList = supportedObjectRecList(concrete)
  if recList.kind != nnkRecList:
    return false

  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return false
    let fieldType = child[^2]
    if not ondemandLeafTypeNode(fieldType):
      return false
  true

proc nativePlanFieldSupportedTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  let typeInst = concrete.getTypeInst

  if isBorrowedStringTypeNode(concrete):
    return true

  if supportedObjectRecList(concrete).kind == nnkRecList:
    let recList = supportedObjectRecList(concrete)
    for child in recList:
      if child.kind != nnkIdentDefs or child.len < 3:
        return false
      let fieldType = child[^2]
      if not nativePlanFieldSupportedTypeNode(fieldType):
        return false
    return true

  if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "seq"):
    return supportedObjectRecList(typeInst[1]).kind == nnkRecList and nativePlanFieldSupportedTypeNode(typeInst[1])

  case concrete.typeKind
  of ntyString, ntyBool,
     ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64,
     ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64,
     ntyFloat, ntyFloat32, ntyFloat64:
    true
  else:
    false

proc nativePlanSupportedRootTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  let recList = supportedObjectRecList(concrete)
  if recList.kind != nnkRecList:
    return false
  var hasSeqObjectField = false
  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return false
    let fieldType = child[^2]
    if not nativePlanFieldSupportedTypeNode(fieldType):
      return false
    let typeInst = unwrapTypedescNode(fieldType).getTypeInst
    if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "seq") and
        supportedObjectRecList(typeInst[1]).kind == nnkRecList:
      hasSeqObjectField = true
  hasSeqObjectField

proc mediumTodoEnvelopeShapeNode(typeNode: NimNode): bool
proc nestedProjectEnvelopeShapeNode(typeNode: NimNode): bool

proc jsonDecodeTierNode(typeNode: NimNode): JsonDecodeTier =
  let concrete = unwrapTypedescNode(typeNode)
  if mediumTodoEnvelopeShapeNode(concrete):
    return jdtNativePlan
  if nestedProjectEnvelopeShapeNode(concrete):
    return jdtNativePlan
  if nativePlanSupportedRootTypeNode(concrete):
    return jdtNativePlan
  if ondemandPreferredTypeNode(concrete):
    return jdtOndemandLeaf
  if ondemandSupportedTypeNode(concrete):
    return jdtDomFallback
  jdtUnsupported

macro jsonDecodeTier*(typeNode: typedesc): untyped =
  let tier = jsonDecodeTierNode(typeNode)
  case tier
  of jdtUnsupported:
    bindSym"jdtUnsupported"
  of jdtDomFallback:
    bindSym"jdtDomFallback"
  of jdtOndemandLeaf:
    bindSym"jdtOndemandLeaf"
  of jdtNativePlan:
    bindSym"jdtNativePlan"

macro requireNativeJsonPlan*(typeNode: typedesc): untyped =
  let tier = jsonDecodeTierNode(typeNode)
  if tier != jdtNativePlan:
    error("native json plan is not available for " & typeNode.repr & "; detected tier " & $tier, typeNode)
  newEmptyNode()

macro requireOndemandLeafJsonPlan*(typeNode: typedesc): untyped =
  let tier = jsonDecodeTierNode(typeNode)
  if tier != jdtOndemandLeaf:
    error("ondemand leaf json plan is not available for " & typeNode.repr & "; detected tier " & $tier, typeNode)
  newEmptyNode()

macro isMediumTodoEnvelopeShape(typeNode: typedesc): untyped =
  newLit(mediumTodoEnvelopeShapeNode(typeNode))

macro isNestedProjectEnvelopeShape*(typeNode: typedesc): untyped =
  newLit(nestedProjectEnvelopeShapeNode(typeNode))

proc objectFieldTypeNode(typeNode: NimNode, fieldName: string): NimNode =
  let recList = supportedObjectRecList(typeNode)
  if recList.kind != nnkRecList:
    return newEmptyNode()
  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      continue
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind == nnkIdent and $fieldNode == fieldName:
        return child[^2]
  newEmptyNode()

proc seqElementTypeNode(typeNode: NimNode): NimNode =
  let concrete = unwrapTypedescNode(typeNode)
  let typeInst = concrete.getTypeInst
  if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "seq"):
    return typeInst[1]
  newEmptyNode()

proc jsonSchemaFieldKindNode(typeNode: NimNode): JsonSchemaFieldKind =
  let concrete = unwrapTypedescNode(typeNode)
  if isBorrowedStringTypeNode(concrete):
    return jsfkBorrowedString

  let typeInst = concrete.getTypeInst
  if typeInst.kind == nnkBracketExpr:
    if typeInst.len == 2 and eqIdent(typeInst[0], "Option"):
      return jsfkOption
    if typeInst.len == 2 and eqIdent(typeInst[0], "seq"):
      return jsfkSeq
    if typeInst.len == 2 and eqIdent(typeInst[0], "ref"):
      return jsfkRef
    if typeInst.len == 3 and eqIdent(typeInst[0], "array"):
      return jsfkArray

  if supportedObjectRecList(concrete).kind == nnkRecList:
    return jsfkObject

  case concrete.typeKind
  of ntyString:
    jsfkString
  of ntyBool:
    jsfkBool
  of ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64:
    jsfkSignedInt
  of ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64:
    jsfkUnsignedInt
  of ntyFloat, ntyFloat32, ntyFloat64:
    jsfkFloat
  of ntyChar:
    jsfkChar
  of ntyEnum:
    jsfkEnum
  else:
    jsfkUnsupported

proc jsonSchemaFieldKindNodeAst(kind: JsonSchemaFieldKind): NimNode =
  case kind
  of jsfkUnsupported: bindSym"jsfkUnsupported"
  of jsfkObject: bindSym"jsfkObject"
  of jsfkSeq: bindSym"jsfkSeq"
  of jsfkArray: bindSym"jsfkArray"
  of jsfkOption: bindSym"jsfkOption"
  of jsfkRef: bindSym"jsfkRef"
  of jsfkString: bindSym"jsfkString"
  of jsfkBorrowedString: bindSym"jsfkBorrowedString"
  of jsfkBool: bindSym"jsfkBool"
  of jsfkSignedInt: bindSym"jsfkSignedInt"
  of jsfkUnsignedInt: bindSym"jsfkUnsignedInt"
  of jsfkFloat: bindSym"jsfkFloat"
  of jsfkChar: bindSym"jsfkChar"
  of jsfkEnum: bindSym"jsfkEnum"

proc jsonDecodeTierNodeAst(tier: JsonDecodeTier): NimNode =
  case tier
  of jdtUnsupported: bindSym"jdtUnsupported"
  of jdtDomFallback: bindSym"jdtDomFallback"
  of jdtOndemandLeaf: bindSym"jdtOndemandLeaf"
  of jdtNativePlan: bindSym"jdtNativePlan"

proc nativePlanSubtreeSizeNode(typeNode: NimNode): int

proc buildJsonSchemaFieldPlanNode(typeNode: NimNode; fieldName = ""): NimNode =
  let concrete = unwrapTypedescNode(typeNode)
  let kind = jsonSchemaFieldKindNode(concrete)
  let tier = jsonDecodeTierNode(concrete)
  var children = newNimNode(nnkBracket)
  let typeInst = concrete.getTypeInst
  case kind
  of jsfkObject:
    let recList = supportedObjectRecList(concrete)
    if recList.kind == nnkRecList:
      for child in recList:
        if child.kind != nnkIdentDefs or child.len < 3:
          continue
        let childType = child[^2]
        for index in 0 ..< child.len - 2:
          var fieldNode = child[index]
          if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
            fieldNode = fieldNode[1]
          if fieldNode.kind == nnkIdent:
            children.add(buildJsonSchemaFieldPlanNode(childType, $fieldNode))
  of jsfkSeq, jsfkOption, jsfkRef:
    if typeInst.kind == nnkBracketExpr and typeInst.len == 2:
      children.add(buildJsonSchemaFieldPlanNode(typeInst[1]))
  of jsfkArray:
    if typeInst.kind == nnkBracketExpr and typeInst.len == 3:
      children.add(buildJsonSchemaFieldPlanNode(typeInst[2]))
  else:
    discard

  let childrenExpr = nnkPrefix.newTree(ident"@", children)
  nnkObjConstr.newTree(
    bindSym"JsonSchemaFieldPlan",
    nnkExprColonExpr.newTree(ident"name", newLit(fieldName)),
    nnkExprColonExpr.newTree(ident"kind", jsonSchemaFieldKindNodeAst(kind)),
    nnkExprColonExpr.newTree(ident"decodeTier", jsonDecodeTierNodeAst(tier)),
    nnkExprColonExpr.newTree(ident"borrowedPreferred", newLit(kind == jsfkBorrowedString)),
    nnkExprColonExpr.newTree(ident"children", childrenExpr)
  )

proc buildJsonDirectFieldPlanNode(typeNode: NimNode; fieldName = ""; ordinal = 0): NimNode =
  let concrete = unwrapTypedescNode(typeNode)
  let kind = jsonSchemaFieldKindNode(concrete)
  let tier = jsonDecodeTierNode(concrete)
  var children = newNimNode(nnkBracket)
  let typeInst = concrete.getTypeInst
  case kind
  of jsfkObject:
    let recList = supportedObjectRecList(concrete)
    if recList.kind == nnkRecList:
      var childOrdinal = 0
      for child in recList:
        if child.kind != nnkIdentDefs or child.len < 3:
          continue
        let childType = child[^2]
        for index in 0 ..< child.len - 2:
          var fieldNode = child[index]
          if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
            fieldNode = fieldNode[1]
          if fieldNode.kind == nnkIdent:
            children.add(buildJsonDirectFieldPlanNode(childType, $fieldNode, childOrdinal))
            inc childOrdinal
  of jsfkSeq, jsfkOption, jsfkRef:
    if typeInst.kind == nnkBracketExpr and typeInst.len == 2:
      children.add(buildJsonDirectFieldPlanNode(typeInst[1], "", 0))
  of jsfkArray:
    if typeInst.kind == nnkBracketExpr and typeInst.len == 3:
      children.add(buildJsonDirectFieldPlanNode(typeInst[2], "", 0))
  else:
    discard

  let childrenExpr = nnkPrefix.newTree(ident"@", children)
  nnkObjConstr.newTree(
    bindSym"JsonDirectFieldPlan",
    nnkExprColonExpr.newTree(ident"name", newLit(fieldName)),
    nnkExprColonExpr.newTree(ident"kind", jsonSchemaFieldKindNodeAst(kind)),
    nnkExprColonExpr.newTree(ident"decodeTier", jsonDecodeTierNodeAst(tier)),
    nnkExprColonExpr.newTree(ident"borrowedPreferred", newLit(kind == jsfkBorrowedString)),
    nnkExprColonExpr.newTree(ident"ordinal", newLit(ordinal)),
    nnkExprColonExpr.newTree(ident"nativeSubtreeSize", newLit(nativePlanSubtreeSizeNode(concrete))),
    nnkExprColonExpr.newTree(ident"children", childrenExpr)
  )

macro jsonSchemaPlan*(typeNode: typedesc): untyped =
  let concrete = unwrapTypedescNode(typeNode)
  var fields = newNimNode(nnkBracket)
  if supportedObjectRecList(concrete).kind == nnkRecList:
    let recList = supportedObjectRecList(concrete)
    for child in recList:
      if child.kind != nnkIdentDefs or child.len < 3:
        continue
      let childType = child[^2]
      for index in 0 ..< child.len - 2:
        var fieldNode = child[index]
        if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
          fieldNode = fieldNode[1]
        if fieldNode.kind == nnkIdent:
          fields.add(buildJsonSchemaFieldPlanNode(childType, $fieldNode))

  let fieldsExpr = nnkPrefix.newTree(ident"@", fields)
  nnkObjConstr.newTree(
    bindSym"JsonSchemaPlan",
    nnkExprColonExpr.newTree(ident"tier", jsonDecodeTierNodeAst(jsonDecodeTierNode(concrete))),
    nnkExprColonExpr.newTree(ident"fields", fieldsExpr)
  )

macro jsonDirectDecodePlan*(typeNode: typedesc): untyped =
  let concrete = unwrapTypedescNode(typeNode)
  var fields = newNimNode(nnkBracket)
  if supportedObjectRecList(concrete).kind == nnkRecList:
    let recList = supportedObjectRecList(concrete)
    var ordinal = 0
    for child in recList:
      if child.kind != nnkIdentDefs or child.len < 3:
        continue
      let childType = child[^2]
      for index in 0 ..< child.len - 2:
        var fieldNode = child[index]
        if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
          fieldNode = fieldNode[1]
        if fieldNode.kind == nnkIdent:
          fields.add(buildJsonDirectFieldPlanNode(childType, $fieldNode, ordinal))
          inc ordinal

  let fieldsExpr = nnkPrefix.newTree(ident"@", fields)
  nnkObjConstr.newTree(
    bindSym"JsonDirectDecodePlan",
    nnkExprColonExpr.newTree(ident"tier", jsonDecodeTierNodeAst(jsonDecodeTierNode(concrete))),
    nnkExprColonExpr.newTree(ident"fields", fieldsExpr)
  )

proc estimateJsonSize[T](value: Option[T]): int
proc estimateJsonSize[T](value: seq[T]): int
proc estimateJsonSize[T, N](value: array[N, T]): int
proc estimateJsonSize[T: object](value: T): int
proc estimateJsonSize[T: object](value: ref T): int

proc estimateJsonSize(value: string): int {.inline.} =
  checkedJsonAdd(value.len, 2)

proc estimateJsonSize(value: BorrowedString): int {.inline.} =
  checkedJsonAdd(value.len, 2)

proc estimateJsonSize(value: cstring): int {.inline.} =
  if value == nil: 4 else: checkedJsonAdd(len($value), 2)

proc estimateJsonSize(value: bool): int {.inline.} =
  if value: 4 else: 5

proc estimateJsonSize[T: SomeInteger](value: T): int {.inline.} =
  discard value
  when T is SomeUnsignedInt:
    20
  else:
    21

proc estimateJsonSize[T: SomeFloat](value: T): int {.inline.} =
  discard value
  24

proc estimateJsonSize(value: char): int {.inline.} =
  4

proc estimateJsonSize[T](value: Option[T]): int =
  if value.isSome: estimateJsonSize(value.get()) else: 4

proc estimateJsonSize[T](value: seq[T]): int =
  result = 2
  if value.len > 1:
    result = checkedJsonAdd(result, value.len - 1)
  for item in value:
    result = checkedJsonAdd(result, estimateJsonSize(item))

proc estimateJsonSize[T, N](value: array[N, T]): int =
  result = 2
  if N > 1:
    result = checkedJsonAdd(result, N - 1)
  for item in value:
    result = checkedJsonAdd(result, estimateJsonSize(item))

proc estimateJsonSize[T: enum](value: T): int {.inline.} =
  discard value
  18

proc estimateJsonSize[T: object](value: T): int =
  result = 2
  var first = true
  for key, field in fieldPairs(value):
    if not first:
      result = checkedJsonAdd(result, 1)
    first = false
    result = checkedJsonAdd(result, checkedJsonAdd(key.len, 3))
    result = checkedJsonAdd(result, estimateJsonSize(field))

proc estimateJsonSize[T: object](value: ref T): int =
  if value == nil: 4 else: estimateJsonSize(value[])

proc initialJsonCapacity(value: string): int {.inline.} =
  max(64, checkedJsonAdd(value.len, 2))

proc initialJsonCapacity(value: BorrowedString): int {.inline.} =
  max(64, checkedJsonAdd(value.len, 2))

proc initialJsonCapacity(value: cstring): int {.inline.} =
  if value == nil: 4 else: max(64, checkedJsonAdd(len($value), 2))

proc initialJsonCapacity(value: bool): int {.inline.} =
  8

proc initialJsonCapacity[T: SomeInteger](value: T): int {.inline.} =
  discard value
  24

proc initialJsonCapacity[T: SomeFloat](value: T): int {.inline.} =
  discard value
  32

proc initialJsonCapacity(value: char): int {.inline.} =
  8

proc initialJsonCapacity[T: enum](value: T): int {.inline.} =
  discard value
  24

proc initialJsonCapacity[T](value: Option[T]): int {.inline.} =
  if value.isSome: initialJsonCapacity(value.get()) else: 8

proc initialJsonCapacityField[T](value: T): int {.inline.}

proc sampleJsonCapacity[T](items: openArray[T]): int {.inline.} =
  if items.len == 0:
    return 24
  var total = 0
  for item in items:
    total = checkedJsonAdd(total, initialJsonCapacityField(item))
  max(24, total div items.len)

proc initialJsonCapacity[T](value: seq[T]): int {.inline.} =
  if value.len == 0:
    return 64
  let sampleCount = min(value.len, 4)
  let avgItem = sampleJsonCapacity(value.toOpenArray(0, sampleCount - 1))
  max(64, checkedJsonAdd(2, checkedJsonAdd(value.len - 1,
    checkedJsonMul(value.len, avgItem))))

proc initialJsonCapacity[T, N](value: array[N, T]): int {.inline.} =
  if N == 0:
    return 64
  let sampleCount = min(N, 4)
  let avgItem = sampleJsonCapacity(value.toOpenArray(0, sampleCount - 1))
  max(64, checkedJsonAdd(2, checkedJsonAdd(N - 1, checkedJsonMul(N, avgItem))))

proc initialJsonCapacityField[T](value: T): int {.inline.} =
  when T is object:
    max(64, sizeof(T) * 24)
  elif T is ref object:
    if value == nil: 4 else: max(64, sizeof(T[]) * 24)
  else:
    initialJsonCapacity(value)

proc initialJsonCapacityObjectRuntime[T: object](value: T): int {.inline.} =
  discard value
  max(128, sizeof(T) * 24)

proc initialJsonCapacity[T: object](value: ref T): int {.inline.} =
  if value == nil: 4 else: initialJsonCapacity(value[])

proc appendJsonValue[T](buf: var string, value: Option[T])
proc appendJsonValue[T](buf: var string, value: seq[T])
proc appendJsonValue[T, N](buf: var string, value: array[N, T])
proc appendJsonValue[T: enum](buf: var string, value: T)
proc appendJsonValue[T: object](buf: var string, value: T)
proc appendJsonValue[T: object](buf: var string, value: ref T)

proc appendJsonValue(buf: var string, value: string) {.inline.} =
  appendEscapedJsonString(buf, value)

proc appendJsonValue(buf: var string, value: BorrowedString) =
  if value.isNil:
    buf.add("\"\"")
    return
  appendEscapedJsonBytes(buf, value.data, value.len)

proc appendJsonValue(buf: var string, value: cstring) {.inline.} =
  if value == nil:
    buf.add("null")
  else:
    appendEscapedJsonString(buf, $value)

proc appendJsonValue(buf: var string, value: bool) {.inline.} =
  if value:
    buf.add("true")
  else:
    buf.add("false")

proc appendJsonValue[T: SomeSignedInt](buf: var string, value: T) {.inline.} =
  buf.addInt(int64(value))

proc appendJsonValue[T: SomeUnsignedInt](buf: var string, value: T) {.inline.} =
  buf.addInt(uint64(value))

proc appendJsonValue[T: SomeFloat](buf: var string, value: T) {.inline.} =
  let asFloat = float64(value)
  let kind = classify(asFloat)
  if kind in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "cannot serialize non-finite float to JSON")
  buf.addFloat(value)

proc appendJsonValue(buf: var string, value: char) {.inline.} =
  buf.add('"')
  case value
  of '"':
    buf.add("\\\"")
  of '\\':
    buf.add("\\\\")
  of '\b':
    buf.add("\\b")
  of '\f':
    buf.add("\\f")
  of '\n':
    buf.add("\\n")
  of '\r':
    buf.add("\\r")
  of '\t':
    buf.add("\\t")
  else:
    if ord(value) < 0x20:
      buf.add("\\u00")
      buf.add(HexDigits[(ord(value) shr 4) and 0xF])
      buf.add(HexDigits[ord(value) and 0xF])
    else:
      buf.add(value)
  buf.add('"')

proc appendJsonValue[T](buf: var string, value: Option[T]) =
  if value.isSome:
    appendJsonValue(buf, value.get())
  else:
    buf.add("null")

proc appendJsonValue[T](buf: var string, value: seq[T]) =
  buf.add('[')
  for i, item in value:
    if i > 0:
      buf.add(',')
    appendJsonValue(buf, item)
  buf.add(']')

proc appendJsonValue[T, N](buf: var string, value: array[N, T]) =
  buf.add('[')
  for i, item in value:
    if i > 0:
      buf.add(',')
    appendJsonValue(buf, item)
  buf.add(']')

proc appendJsonValue[T: enum](buf: var string, value: T) =
  appendEscapedJsonString(buf, $value)

proc appendJsonObjectRuntime[T: object](buf: var string, value: T) =
  buf.add('{')
  var first = true
  for key, field in fieldPairs(value):
    if not first:
      buf.add(',')
    first = false
    appendObjectKey(buf, key)
    appendJsonValue(buf, field)
  buf.add('}')

macro initialJsonCapacityObjectFast(typeNode: typedesc, valueExpr: typed): untyped =
  let recList = supportedObjectRecList(typeNode)
  if recList.kind != nnkRecList:
    return quote do:
      initialJsonCapacityObjectRuntime(`valueExpr`)

  let valueSym = genSym(nskLet, "value")
  let resultSym = genSym(nskVar, "result")
  let stmts = newStmtList()
  var fieldCount = 0
  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return quote do:
        initialJsonCapacityObjectRuntime(`valueExpr`)
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind != nnkIdent:
        return quote do:
          initialJsonCapacityObjectRuntime(`valueExpr`)
      let fieldName = $fieldNode
      let keyOverhead = newLit(fieldName.len + 4)
      let fieldAccess = nnkDotExpr.newTree(valueSym, fieldNode)
      stmts.add(
        quote do:
          `resultSym` += `keyOverhead`
          `resultSym` += initialJsonCapacityField(`fieldAccess`)
      )
      inc fieldCount

  result = quote do:
    block:
      let `valueSym` = `valueExpr`
      var `resultSym` = 2
      if `fieldCount` > 1:
        `resultSym` += `fieldCount - 1`
      `stmts`
      max(64, `resultSym`)

macro appendJsonObjectFast(typeNode: typedesc, bufExpr: typed, valueExpr: typed): untyped =
  let recList = supportedObjectRecList(typeNode)
  if recList.kind != nnkRecList:
    return quote do:
      appendJsonObjectRuntime(`bufExpr`, `valueExpr`)

  let valueSym = genSym(nskLet, "value")
  let stmts = newStmtList()
  var fieldCount = 0
  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return quote do:
        appendJsonObjectRuntime(`bufExpr`, `valueExpr`)
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind != nnkIdent:
        return quote do:
          appendJsonObjectRuntime(`bufExpr`, `valueExpr`)
      let fieldAccess = nnkDotExpr.newTree(valueSym, fieldNode)
      let keyPrefix =
        if fieldCount == 0:
          "{\"" & $fieldNode & "\":"
        else:
          ",\"" & $fieldNode & "\":"
      let keyPrefixLit = newLit(keyPrefix)
      stmts.add(
        quote do:
          `bufExpr`.add(`keyPrefixLit`)
          appendJsonValue(`bufExpr`, `fieldAccess`)
      )
      inc fieldCount

  result =
    if fieldCount == 0:
      quote do:
        `bufExpr`.add("{}")
    else:
      quote do:
        block:
          let `valueSym` = `valueExpr`
          `stmts`
          `bufExpr`.add('}')

proc initialJsonCapacity[T: object](value: T): int {.inline.} =
  initialJsonCapacityObjectFast(T, value)

proc appendJsonValue[T: object](buf: var string, value: T) =
  appendJsonObjectFast(T, buf, value)

proc appendJsonValue[T: object](buf: var string, value: ref T) =
  if value == nil:
    buf.add("null")
  else:
    appendJsonValue(buf, value[])

proc decodeJson[T: object](cursor: ObjectCursor, _: typedesc[T]): T
proc decodeJson[T: object](value: Value, _: typedesc[T]): T

proc decodeProjectedField[T](field: ProjectedField, _: typedesc[Option[T]]): Option[T]
proc decodeProjectedField[T: object](field: ProjectedField, _: typedesc[T]): T
proc decodeProjectedField[T](field: ProjectedField, _: typedesc[ref T]): ref T

proc decodeInteger[T: SomeInteger](value: Value): T =
  case value.kind
  of jkInt64:
    let raw = value.getInt64()
    when T is SomeUnsignedInt:
      if raw < 0:
        raise newException(ValueError, "negative JSON integer cannot decode into unsigned type")
      if uint64(raw) > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
    else:
      if raw < int64(low(T)) or raw > int64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
  of jkUint64:
    let raw = value.getUint64()
    when T is SomeUnsignedInt:
      if raw > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
    else:
      if raw > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
  else:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeFloat[T: SomeFloat](value: Value): T =
  case value.kind
  of jkDouble:
    T(value.getFloat64())
  of jkInt64:
    T(value.getInt64())
  of jkUint64:
    T(value.getUint64())
  else:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeEnum[T: enum](value: Value): T =
  let raw = value.getStr()
  for candidate in low(T) .. high(T):
    if $candidate == raw:
      return candidate
  raise newException(ValueError, "unknown enum value: " & raw)

proc decodeJson(value: Value, _: typedesc[string]): string =
  value.getStr()

proc decodeJson(value: Value, _: typedesc[BorrowedString]): BorrowedString =
  value.getStrView()

proc decodeJson(value: Value, _: typedesc[bool]): bool =
  value.getBool()

proc decodeJson[T: SomeInteger](value: Value, _: typedesc[T]): T =
  decodeInteger[T](value)

proc decodeJson[T: SomeFloat](value: Value, _: typedesc[T]): T =
  decodeFloat[T](value)

proc decodeJson(value: Value, _: typedesc[char]): char =
  let raw = value.getStr()
  if raw.len != 1:
    raise newException(ValueError, "JSON string must have length 1 to decode into char")
  raw[0]

proc decodeJson[T: enum](value: Value, _: typedesc[T]): T =
  decodeEnum[T](value)

proc decodeJson[T](value: Value, _: typedesc[Option[T]]): Option[T] =
  if value.isNil or value.isNull:
    none(T)
  else:
    some(decodeJson(value, T))

proc decodeJson[T](value: Value, _: typedesc[seq[T]]): seq[T] =
  let items = value.arrayCursor()
  let handles = collectArrayHandles(items)
  let itemsLen = handles.len
  result = newSeq[T](itemsLen)
  for i in 0 ..< itemsLen:
    result[i] = decodeJson(newValue(items.requireStorage(), handles[i]), T)

proc decodeJson[T, N](value: Value, _: typedesc[array[N, T]]): array[N, T] =
  let items = value.arrayCursor()
  let handles = collectArrayHandles(items)
  let itemsLen = handles.len
  if itemsLen != result.len:
    raise newException(ValueError, "JSON array length does not match target array size")
  for i in 0 .. high(result):
    result[i] = decodeJson(newValue(items.requireStorage(), handles[i]), T)

proc decodeProjectedField(field: ProjectedField, _: typedesc[string]): string {.inline.} =
  if field.kind != jkString:
    raise raiseError(simdjsonIncorrectTypeCode())
  field.stringValue.toString()

proc decodeProjectedField(field: ProjectedField, _: typedesc[BorrowedString]): BorrowedString {.inline.} =
  if field.kind != jkString:
    raise raiseError(simdjsonIncorrectTypeCode())
  field.stringValue

proc decodeProjectedField(field: ProjectedField, _: typedesc[bool]): bool {.inline.} =
  if field.kind != jkBool:
    raise raiseError(simdjsonIncorrectTypeCode())
  field.boolValue

proc decodeProjectedField[T: SomeInteger](field: ProjectedField, _: typedesc[T]): T {.inline.} =
  case field.kind
  of jkInt64:
    let raw = field.int64Value
    when T is SomeUnsignedInt:
      if raw < 0 or uint64(raw) > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
    else:
      if raw < int64(low(T)) or raw > int64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
  of jkUint64:
    let raw = field.uint64Value
    when T is SomeUnsignedInt:
      if raw > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
    else:
      if raw > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
  else:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeProjectedField[T: SomeFloat](field: ProjectedField, _: typedesc[T]): T {.inline.} =
  case field.kind
  of jkDouble:
    T(field.float64Value)
  of jkInt64:
    T(field.int64Value)
  of jkUint64:
    T(field.uint64Value)
  else:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeProjectedField(field: ProjectedField, _: typedesc[char]): char {.inline.} =
  let raw = decodeProjectedField(field, string)
  if raw.len != 1:
    raise newException(ValueError, "JSON string must have length 1 to decode into char")
  raw[0]

proc decodeProjectedField[T: enum](field: ProjectedField, _: typedesc[T]): T {.inline.} =
  let raw = decodeProjectedField(field, string)
  for candidate in low(T) .. high(T):
    if $candidate == raw:
      return candidate
  raise newException(ValueError, "unknown enum value: " & raw)

proc decodeProjectedField[T](field: ProjectedField, _: typedesc[Option[T]]): Option[T] =
  if not field.present or field.kind == jkNull:
    none(T)
  else:
    some(decodeProjectedField(field, T))

proc decodeProjectedField[T](field: ProjectedField, _: typedesc[seq[T]]): seq[T] =
  let items = field.arrayCursor()
  let handles = collectArrayHandles(items)
  let itemsLen = handles.len
  result = newSeq[T](itemsLen)
  for i in 0 ..< itemsLen:
    result[i] = decodeJson(newValue(items.requireStorage(), handles[i]), T)

proc decodeProjectedField[T, N](field: ProjectedField, _: typedesc[array[N, T]]): array[N, T] =
  let items = field.arrayCursor()
  let handles = collectArrayHandles(items)
  let itemsLen = handles.len
  if itemsLen != result.len:
    raise newException(ValueError, "JSON array length does not match target array size")
  for i in 0 .. high(result):
    result[i] = decodeJson(newValue(items.requireStorage(), handles[i]), T)

proc decodeProjectedField[T: object](field: ProjectedField, _: typedesc[T]): T =
  decodeJson(field.objectCursor(), T)

proc decodeProjectedField[T](field: ProjectedField, _: typedesc[ref T]): ref T =
  if not field.present or field.kind == jkNull:
    return nil
  new(result)
  result[] = decodeProjectedField(field, T)

proc decodeRawProjectEntry(entry: CProjectEntry, storage: DocStorage, _: typedesc[string]): string {.inline.} =
  if kindFromInt(entry.found_kind) != jkString:
    raise raiseError(simdjsonIncorrectTypeCode())
  copyCString(entry.str_data, entry.str_len)

proc decodeRawProjectEntry(entry: CProjectEntry, storage: DocStorage, _: typedesc[BorrowedString]): BorrowedString {.inline.} =
  if kindFromInt(entry.found_kind) != jkString:
    raise raiseError(simdjsonIncorrectTypeCode())
  borrowString(storage, entry.str_data, entry.str_len)

proc decodeRawProjectEntry(entry: CProjectEntry, storage: DocStorage, _: typedesc[bool]): bool {.inline.} =
  discard storage
  if kindFromInt(entry.found_kind) != jkBool:
    raise raiseError(simdjsonIncorrectTypeCode())
  entry.bool_value

proc decodeRawProjectEntry[T: SomeInteger](entry: CProjectEntry, storage: DocStorage, _: typedesc[T]): T {.inline.} =
  discard storage
  case kindFromInt(entry.found_kind)
  of jkInt64:
    let raw = entry.int64_value
    when T is SomeUnsignedInt:
      if raw < 0 or uint64(raw) > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
    else:
      if raw < int64(low(T)) or raw > int64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
  of jkUint64:
    let raw = entry.uint64_value
    when T is SomeUnsignedInt:
      if raw > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
    else:
      if raw > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
  else:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeRawProjectEntry[T: SomeFloat](entry: CProjectEntry, storage: DocStorage, _: typedesc[T]): T {.inline.} =
  discard storage
  case kindFromInt(entry.found_kind)
  of jkDouble:
    T(entry.double_value)
  of jkInt64:
    T(entry.int64_value)
  of jkUint64:
    T(entry.uint64_value)
  else:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeRawProjectEntry(entry: CProjectEntry, storage: DocStorage, _: typedesc[char]): char {.inline.} =
  let raw = decodeRawProjectEntry(entry, storage, string)
  if raw.len != 1:
    raise newException(ValueError, "JSON string must have length 1 to decode into char")
  raw[0]

proc decodeRawProjectEntry[T: enum](entry: CProjectEntry, storage: DocStorage, _: typedesc[T]): T {.inline.} =
  let raw = decodeRawProjectEntry(entry, storage, string)
  for candidate in low(T) .. high(T):
    if $candidate == raw:
      return candidate
  raise newException(ValueError, "unknown enum value: " & raw)

proc decodeRawProjectEntry[T](entry: CProjectEntry, storage: DocStorage, _: typedesc[Option[T]]): Option[T] =
  if entry.status != simdjsonSuccessCode() or kindFromInt(entry.found_kind) == jkNull:
    none(T)
  else:
    some(decodeRawProjectEntry(entry, storage, T))

proc decodeRawProjectEntry[T](entry: CProjectEntry, storage: DocStorage, _: typedesc[seq[T]]): seq[T] =
  if kindFromInt(entry.found_kind) != jkArray:
    raise raiseError(simdjsonIncorrectTypeCode())
  let child = newValue(storage, entry.child_handle)
  decodeJson(child, seq[T])

proc decodeRawProjectEntry[T, N](entry: CProjectEntry, storage: DocStorage, _: typedesc[array[N, T]]): array[N, T] =
  if kindFromInt(entry.found_kind) != jkArray:
    raise raiseError(simdjsonIncorrectTypeCode())
  let child = newValue(storage, entry.child_handle)
  decodeJson(child, array[N, T])

proc decodeRawProjectEntry[T: object](entry: CProjectEntry, storage: DocStorage, _: typedesc[T]): T =
  if kindFromInt(entry.found_kind) != jkObject:
    raise raiseError(simdjsonIncorrectTypeCode())
  let child = newValue(storage, entry.child_handle)
  decodeJson(child, T)

proc decodeRawProjectEntry[T](entry: CProjectEntry, storage: DocStorage, _: typedesc[ref T]): ref T =
  if entry.status != simdjsonSuccessCode() or kindFromInt(entry.found_kind) == jkNull:
    return nil
  new(result)
  result[] = decodeRawProjectEntry(entry, storage, T)

proc decodeOndemandJson[T](data: cstring, len: csize_t, _: typedesc[T]): T
proc decodeOndemandObjectJson[T: object](data: cstring, len: csize_t, _: typedesc[T]): T
proc decodeGeneratedDirectObjectJson[T: object](data: cstring, len: csize_t, _: typedesc[T]): T
proc decodeGeneratedDirectSeqObjectJson[T: object](data: cstring, len: csize_t, _: typedesc[T]): seq[T]

proc directDecodeLeafTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  if isBorrowedStringTypeNode(concrete):
    return false

  let recList = supportedObjectRecList(concrete)
  if recList.kind == nnkRecList:
    for child in recList:
      if child.kind != nnkIdentDefs or child.len < 3:
        return false
      let fieldType = child[^2]
      if not directDecodeLeafTypeNode(fieldType):
        return false
    return true

  case concrete.typeKind
  of ntyString, ntyBool,
     ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64,
     ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64,
     ntyFloat, ntyFloat32, ntyFloat64:
    true
  else:
    false

proc directDecodeSupportedTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  if directDecodeLeafTypeNode(concrete):
    return true

  let recList = supportedObjectRecList(concrete)
  if recList.kind == nnkRecList:
    for child in recList:
      if child.kind != nnkIdentDefs or child.len < 3:
        return false
      let fieldType = unwrapTypedescNode(child[^2])
      if directDecodeLeafTypeNode(fieldType):
        continue
      let fieldInst = fieldType.getTypeInst
      if fieldInst.kind == nnkBracketExpr and fieldInst.len == 2 and eqIdent(fieldInst[0], "seq") and
          directDecodeLeafTypeNode(fieldInst[1]):
        continue
      return false
    return true

  let typeInst = concrete.getTypeInst
  if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "seq"):
    return directDecodeLeafTypeNode(typeInst[1])

  false

macro directDecodeSupported*(typeNode: typedesc): untyped =
  newLit(directDecodeSupportedTypeNode(typeNode))

proc ensureOndemandKind(foundKind: cint, expected: JsonKind) {.inline.} =
  if foundKind < 0 or kindFromInt(foundKind) != expected:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeOndemandInteger[T: SomeInteger](foundKind: cint, int64Value: int64, uint64Value: uint64): T =
  case kindFromInt(foundKind)
  of jkInt64:
    let raw = int64Value
    when T is SomeUnsignedInt:
      if raw < 0:
        raise newException(ValueError, "negative JSON integer cannot decode into unsigned type")
      if uint64(raw) > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
    else:
      if raw < int64(low(T)) or raw > int64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
  of jkUint64:
    let raw = uint64Value
    when T is SomeUnsignedInt:
      if raw > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
    else:
      if raw > uint64(high(T)):
        raise newException(ValueError, "JSON integer out of range for target type")
      T(raw)
  else:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeOndemandFloat[T: SomeFloat](foundKind: cint, int64Value: int64, uint64Value: uint64, doubleValue: cdouble): T =
  case kindFromInt(foundKind)
  of jkDouble:
    T(doubleValue)
  of jkInt64:
    T(int64Value)
  of jkUint64:
    T(uint64Value)
  else:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeOndemandData(data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[string]): string =
  ensureOndemandKind(foundKind, jkString)
  copyCString(data, len)

proc decodeOndemandData(data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[BorrowedString]): BorrowedString =
  discard boolValue
  discard int64Value
  discard uint64Value
  discard doubleValue
  ensureOndemandKind(foundKind, jkString)
  var storage = CopiedStringStorage(owned: copyCString(data, len))
  BorrowedString(storage: storage, data: storage.owned.cstring, size: csizeToInt(len, "simdjson string"))

proc decodeOndemandData(data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[bool]): bool =
  discard data
  discard len
  discard int64Value
  discard uint64Value
  discard doubleValue
  ensureOndemandKind(foundKind, jkBool)
  boolValue

proc decodeOndemandData[T: SomeInteger](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[T]): T =
  discard data
  discard len
  discard boolValue
  discard doubleValue
  decodeOndemandInteger[T](foundKind, int64Value, uint64Value)

proc decodeOndemandData[T: SomeFloat](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[T]): T =
  discard data
  discard len
  discard boolValue
  decodeOndemandFloat[T](foundKind, int64Value, uint64Value, doubleValue)

proc decodeOndemandData(data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[char]): char =
  discard boolValue
  discard int64Value
  discard uint64Value
  discard doubleValue
  let raw = decodeOndemandData(data, len, foundKind, false, 0, 0, 0.0, string)
  if raw.len != 1:
    raise newException(ValueError, "JSON string must have length 1 to decode into char")
  raw[0]

proc decodeOndemandData[T: enum](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[T]): T =
  discard boolValue
  discard int64Value
  discard uint64Value
  discard doubleValue
  let raw = decodeOndemandData(data, len, foundKind, false, 0, 0, 0.0, string)
  for candidate in low(T) .. high(T):
    if $candidate == raw:
      return candidate
  raise newException(ValueError, "unknown enum value: " & raw)

proc decodeOndemandData[T](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[Option[T]]): Option[T] =
  discard boolValue
  discard int64Value
  discard uint64Value
  discard doubleValue
  if foundKind < 0 or kindFromInt(foundKind) == jkNull:
    none(T)
  else:
    some(decodeOndemandJson(data, len, T))

proc decodeOndemandData[T](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[seq[T]]): seq[T] =
  discard boolValue
  discard int64Value
  discard uint64Value
  discard doubleValue
  ensureOndemandKind(foundKind, jkArray)
  var itemsLen: csize_t
  ensureSuccess(simdjsonOndemandArrayLength(data, len, addr itemsLen))
  let itemCount = csizeToInt(itemsLen, "simdjson array")
  result = newSeq[T](itemCount)
  if itemCount == 0:
    return result
  var items = newSeq[COndemandValue](itemCount)
  try:
    ensureSuccess(simdjsonOndemandCaptureArray(data, len, addr items[0], itemsLen))
    for i in 0 ..< itemCount:
      when T is object:
        result[i] = decodeOndemandObjectJson(items[i].data, items[i].data_len, T)
      else:
        result[i] = decodeOndemandData(items[i].data, items[i].data_len, items[i].found_kind, items[i].bool_value, items[i].int64_value, items[i].uint64_value, items[i].double_value, type(result[i]))
  finally:
    simdjsonOndemandValuesRelease(addr items[0], itemsLen)

proc decodeOndemandData[T, N](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[array[N, T]]): array[N, T] =
  let items = decodeOndemandData(data, len, foundKind, boolValue, int64Value, uint64Value, doubleValue, seq[T])
  if items.len != result.len:
    raise newException(ValueError, "JSON array length does not match target array size")
  for i in 0 .. high(result):
    result[i] = items[i]

proc decodeOndemandData[T: object](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[T]): T =
  discard boolValue
  discard int64Value
  discard uint64Value
  discard doubleValue
  ensureOndemandKind(foundKind, jkObject)
  decodeOndemandObjectJson(data, len, T)

proc decodeOndemandData[T](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[ref T]): ref T =
  discard boolValue
  discard int64Value
  discard uint64Value
  discard doubleValue
  if foundKind < 0 or kindFromInt(foundKind) == jkNull:
    return nil
  decodeOndemandJson(data, len, ref T)

proc decodeGeneratedDirectValue[T: SomeInteger](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[T]): T {.inline.} =
  decodeOndemandData(data, len, foundKind, boolValue, int64Value, uint64Value, doubleValue, T)

proc decodeGeneratedDirectValue[T: SomeFloat](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[T]): T {.inline.} =
  decodeOndemandData(data, len, foundKind, boolValue, int64Value, uint64Value, doubleValue, T)

proc decodeGeneratedDirectValue(data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[string]): string {.inline.} =
  decodeOndemandData(data, len, foundKind, boolValue, int64Value, uint64Value, doubleValue, string)

proc decodeGeneratedDirectValue(data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[bool]): bool {.inline.} =
  decodeOndemandData(data, len, foundKind, boolValue, int64Value, uint64Value, doubleValue, bool)

proc decodeGeneratedDirectValue[T: object](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[T]): T =
  discard boolValue
  discard int64Value
  discard uint64Value
  discard doubleValue
  ensureOndemandKind(foundKind, jkObject)
  decodeGeneratedDirectObjectJson(data, len, T)

proc decodeGeneratedDirectValue[T](data: cstring, len: csize_t, foundKind: cint, boolValue: bool, int64Value: int64, uint64Value: uint64, doubleValue: cdouble, _: typedesc[seq[T]]): seq[T] =
  discard boolValue
  discard int64Value
  discard uint64Value
  discard doubleValue
  ensureOndemandKind(foundKind, jkArray)
  when T is object and directDecodeSupported(T):
    decodeGeneratedDirectSeqObjectJson(data, len, T)
  else:
    var itemsLen: csize_t
    ensureSuccess(simdjsonOndemandArrayLength(data, len, addr itemsLen))
    let itemCount = csizeToInt(itemsLen, "simdjson array")
    result = newSeq[T](itemCount)
    if itemCount == 0:
      return result
    var items = newSeq[COndemandValue](itemCount)
    try:
      ensureSuccess(simdjsonOndemandCaptureArray(data, len, addr items[0], itemsLen))
      for i in 0 ..< result.len:
        result[i] = decodeGeneratedDirectValue(
          items[i].data,
          items[i].data_len,
          items[i].found_kind,
          items[i].bool_value,
          items[i].int64_value,
          items[i].uint64_value,
          items[i].double_value,
          T
        )
    finally:
      simdjsonOndemandValuesRelease(addr items[0], itemsLen)

proc checkedSignedJsonInt[T: SomeInteger](raw: int64): T {.inline.} =
  when T is SomeUnsignedInt:
    if raw < 0 or uint64(raw) > uint64(high(T)):
      raise newException(ValueError, "JSON integer out of range for target type")
    T(raw)
  else:
    if raw < int64(low(T)) or raw > int64(high(T)):
      raise newException(ValueError, "JSON integer out of range for target type")
    T(raw)

proc nativePlanKindNode(typeNode: NimNode): cint =
  let concrete = unwrapTypedescNode(typeNode)
  let typeInst = concrete.getTypeInst
  if isBorrowedStringTypeNode(concrete):
    return cnpkString
  if supportedObjectRecList(concrete).kind == nnkRecList:
    return cnpkObject
  if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "seq") and
      supportedObjectRecList(typeInst[1]).kind == nnkRecList:
    return cnpkSeqObject
  case concrete.typeKind
  of ntyString:
    cnpkString
  of ntyBool:
    cnpkBool
  of ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64:
    cnpkSignedInt
  of ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64:
    cnpkUnsignedInt
  of ntyFloat, ntyFloat32, ntyFloat64:
    cnpkFloat
  else:
    cnpkUnsupported

proc nativePlanChildSpecs(typeNode: NimNode): seq[tuple[name: string, fieldType: NimNode]] =
  let concrete = unwrapTypedescNode(typeNode)
  let recList = supportedObjectRecList(concrete)
  if recList.kind == nnkRecList:
    for child in recList:
      if child.kind != nnkIdentDefs or child.len < 3:
        continue
      let childType = child[^2]
      for index in 0 ..< child.len - 2:
        var fieldNode = child[index]
        if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
          fieldNode = fieldNode[1]
        if fieldNode.kind == nnkIdent:
          result.add(($fieldNode, childType))
    return result

  let typeInst = concrete.getTypeInst
  if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "seq"):
    result.add(("", typeInst[1]))

proc nativePlanSubtreeSizeNode(typeNode: NimNode): int =
  result = 1
  for child in nativePlanChildSpecs(typeNode):
    inc result, nativePlanSubtreeSizeNode(child.fieldType)

proc nativePlanKeyHash(name: string): uint64 {.compileTime.} =
  result = 1469598103934665603'u64
  for ch in name:
    result = result xor uint64(uint8(ch))
    result = result * 1099511628211'u64

proc emitNativePlanInit(
  planSym: NimNode,
  stmts: NimNode,
  typeNode: NimNode,
  fieldName: string,
  nextIndex: var int
) =
  let nodeIndex = nextIndex
  inc nextIndex
  let children = nativePlanChildSpecs(typeNode)
  let nodeIndexLit = newLit(nodeIndex)
  let nameLit = newLit(fieldName)
  let nameHashLit = newLit(nativePlanKeyHash(fieldName))
  let firstCharLit = newLit(if fieldName.len == 0: 0'u8 else: uint8(fieldName[0]))
  let kindLit = newLit(nativePlanKindNode(typeNode))
  let childCountLit = newLit(children.len)
  let subtreeSizeLit = newLit(nativePlanSubtreeSizeNode(typeNode))
  stmts.add quote do:
    `planSym`[`nodeIndexLit`].name = `nameLit`.cstring
    `planSym`[`nodeIndexLit`].name_len = `nameLit`.len.csize_t
    `planSym`[`nodeIndexLit`].name_hash = `nameHashLit`
    `planSym`[`nodeIndexLit`].first_char = `firstCharLit`
    `planSym`[`nodeIndexLit`].kind = `kindLit`
    `planSym`[`nodeIndexLit`].child_count = `childCountLit`.csize_t
    `planSym`[`nodeIndexLit`].subtree_size = `subtreeSizeLit`.csize_t
  for child in children:
    emitNativePlanInit(planSym, stmts, child.fieldType, child.name, nextIndex)

proc ensureNativeValueStatus(value: CNativeValue) {.inline.} =
  if value.status != simdjsonSuccessCode() and value.status != simdjsonNoSuchFieldCode():
    ensureSuccess(value.status)

proc nativeValuePresent(value: CNativeValue): bool {.inline.} =
  value.status == simdjsonSuccessCode() and value.found_kind >= 0

proc ensureNativeKind(value: CNativeValue, expected: JsonKind) {.inline.} =
  ensureNativeValueStatus(value)
  if value.found_kind < 0 or kindFromInt(value.found_kind) != expected:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeNativeInteger[T: SomeInteger](value: CNativeValue): T {.inline.} =
  ensureNativeValueStatus(value)
  if value.found_kind < 0:
    raise raiseError(simdjsonIncorrectTypeCode())
  case kindFromInt(value.found_kind)
  of jkInt64:
    checkedSignedJsonInt[T](value.int64_value)
  of jkUint64:
    if value.uint64_value > uint64(high(T)):
      raise newException(ValueError, "JSON integer out of range for target type")
    T(value.uint64_value)
  else:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeNativeFloat[T: SomeFloat](value: CNativeValue): T {.inline.} =
  ensureNativeValueStatus(value)
  if value.found_kind < 0:
    raise raiseError(simdjsonIncorrectTypeCode())
  case kindFromInt(value.found_kind)
  of jkDouble:
    T(value.double_value)
  of jkInt64:
    T(value.int64_value)
  of jkUint64:
    T(value.uint64_value)
  else:
    raise raiseError(simdjsonIncorrectTypeCode())

proc decodeNativeValue(value: CNativeValue, _: typedesc[string]): string =
  ensureNativeKind(value, jkString)
  copyCString(value.data, value.data_len)

proc decodeNativeValue(value: CNativeValue, storage: StorageOwner, _: typedesc[string]): string {.inline.} =
  discard storage
  decodeNativeValue(value, string)

proc decodeNativeValue(value: CNativeValue, storage: StorageOwner, _: typedesc[BorrowedString]): BorrowedString =
  ensureNativeKind(value, jkString)
  borrowString(storage, value.data, value.data_len)

proc decodeNativeValue(value: CNativeValue, _: typedesc[bool]): bool =
  ensureNativeKind(value, jkBool)
  value.bool_value

proc decodeNativeValue(value: CNativeValue, storage: StorageOwner, _: typedesc[bool]): bool {.inline.} =
  discard storage
  decodeNativeValue(value, bool)

proc decodeNativeValue[T: SomeInteger](value: CNativeValue, _: typedesc[T]): T =
  decodeNativeInteger[T](value)

proc decodeNativeValue[T: SomeInteger](value: CNativeValue, storage: StorageOwner, _: typedesc[T]): T {.inline.} =
  discard storage
  decodeNativeValue(value, T)

proc decodeNativeValue[T: SomeFloat](value: CNativeValue, _: typedesc[T]): T =
  decodeNativeFloat[T](value)

proc decodeNativeValue[T: SomeFloat](value: CNativeValue, storage: StorageOwner, _: typedesc[T]): T {.inline.} =
  discard storage
  decodeNativeValue(value, T)

proc decodeNativeValue[T](value: CNativeValue, _: typedesc[seq[T]]): seq[T]
proc decodeNativeValue[T](value: CNativeValue, storage: StorageOwner, _: typedesc[seq[T]]): seq[T]
proc decodeNativeValue[T: object](value: CNativeValue, _: typedesc[T]): T
proc decodeNativeValue[T: object](value: CNativeValue, storage: StorageOwner, _: typedesc[T]): T

macro decodeNativeObjectValue(typeNode: typedesc, valueExpr: typed, storageExpr: typed): untyped =
  let recList = supportedObjectRecList(typeNode)
  let sourceSym = genSym(nskLet, "source")
  let storageSym = genSym(nskLet, "storage")
  let decodedSym = genSym(nskVar, "decoded")

  template fallback(): untyped =
    quote do:
      let `sourceSym` = `valueExpr`
      let `storageSym` = `storageExpr`
      var `decodedSym`: `typeNode`
      `decodedSym`

  if recList.kind != nnkRecList:
    return fallback()

  let assignStmts = newStmtList()
  var childIndex = 0
  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return fallback()
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind != nnkIdent:
        return fallback()
      let fieldAccess = nnkDotExpr.newTree(decodedSym, fieldNode)
      let childIndexLit = newLit(childIndex)
      let childSym = genSym(nskLet, "child")
      assignStmts.add quote do:
        if `sourceSym`.children_len > `childIndexLit`.csize_t:
          let `childSym` = cast[ptr UncheckedArray[CNativeValue]](`sourceSym`.children)[`childIndexLit`]
          ensureNativeValueStatus(`childSym`)
          if nativeValuePresent(`childSym`):
            `fieldAccess` = decodeNativeValue(`childSym`, `storageSym`, type(`fieldAccess`))
      inc childIndex

  result = quote do:
    block:
      let `sourceSym` = `valueExpr`
      let `storageSym` = `storageExpr`
      ensureNativeKind(`sourceSym`, jkObject)
      var `decodedSym`: `typeNode`
      `assignStmts`
      `decodedSym`

proc decodeNativeValue[T](value: CNativeValue, _: typedesc[seq[T]]): seq[T] =
  ensureNativeKind(value, jkArray)
  result = newSeq[T](csizeToInt(value.children_len, "simdjson array"))
  for i in 0 ..< result.len:
    result[i] = decodeNativeValue(cast[ptr UncheckedArray[CNativeValue]](value.children)[i], T)

proc decodeNativeValue[T](value: CNativeValue, storage: StorageOwner, _: typedesc[seq[T]]): seq[T] =
  ensureNativeKind(value, jkArray)
  result = newSeq[T](csizeToInt(value.children_len, "simdjson array"))
  for i in 0 ..< result.len:
    result[i] = decodeNativeValue(cast[ptr UncheckedArray[CNativeValue]](value.children)[i], storage, T)

proc decodeNativeValue[T: object](value: CNativeValue, _: typedesc[T]): T =
  decodeNativeObjectValue(T, value, StorageOwner(nil))

proc decodeNativeValue[T: object](value: CNativeValue, storage: StorageOwner, _: typedesc[T]): T =
  decodeNativeObjectValue(T, value, storage)

macro decodeNativePlanJson(typeNode: typedesc, dataExpr: typed, lenExpr: typed): untyped =
  if not nativePlanSupportedRootTypeNode(typeNode):
    return quote do:
      let jsonText = copyCString(`dataExpr`, `lenExpr`)
      let doc = parse(jsonText)
      decodeJson(doc.root(), `typeNode`)

  let planSym = genSym(nskVar, "plan")
  let rootSym = genSym(nskVar, "root")
  let initStmts = newStmtList()
  var nextIndex = 0
  emitNativePlanInit(planSym, initStmts, typeNode, "", nextIndex)
  let planLenLit = newLit(nativePlanSubtreeSizeNode(typeNode))

  result = quote do:
    block:
      var `planSym`: array[`planLenLit`, CNativePlanNode]
      `initStmts`
      var `rootSym`: CNativeValue
      ensureSuccess(simdjsonExtractNativePlan(`dataExpr`, `lenExpr`, addr `planSym`[0], `planLenLit`.csize_t, addr `rootSym`))
      let nativeStorage = newNativeValueStorage(`rootSym`)
      decodeNativeValue(nativeStorage.root, nativeStorage, `typeNode`)

proc mediumTodoEnvelopeShapeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  let recList = supportedObjectRecList(concrete)
  if recList.kind != nnkRecList:
    return false

  var todosType = newEmptyNode()
  var metaType = newEmptyNode()
  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return false
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind != nnkIdent:
        return false
      case $fieldNode
      of "todos":
        todosType = child[^2]
      of "meta":
        metaType = child[^2]
      else:
        return false

  if todosType.kind == nnkEmpty or metaType.kind == nnkEmpty:
    return false

  let todosInst = todosType.getTypeInst
  if todosInst.kind != nnkBracketExpr or todosInst.len != 2 or not eqIdent(todosInst[0], "seq"):
    return false

  let todoRecList = supportedObjectRecList(todosInst[1])
  if todoRecList.kind != nnkRecList:
    return false
  var hasTodoId = false
  var hasTodoTitle = false
  var hasTodoCompleted = false
  for child in todoRecList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return false
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind != nnkIdent:
        return false
      let fieldType = child[^2]
      case $fieldNode
      of "id":
        if fieldType.typeKind notin {ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64, ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64}:
          return false
        hasTodoId = true
      of "title":
        if not eqIdent(unwrapTypedescNode(fieldType), "string"):
          return false
        hasTodoTitle = true
      of "completed":
        if fieldType.typeKind != ntyBool:
          return false
        hasTodoCompleted = true
      else:
        return false

  let metaRecList = supportedObjectRecList(metaType)
  if metaRecList.kind != nnkRecList:
    return false
  var hasPage = false
  var hasCount = false
  for child in metaRecList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return false
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind != nnkIdent:
        return false
      let fieldType = child[^2]
      if fieldType.typeKind notin {ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64, ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64}:
        return false
      case $fieldNode
      of "page":
        hasPage = true
      of "count":
        hasCount = true
      else:
        return false

  hasTodoId and hasTodoTitle and hasTodoCompleted and hasPage and hasCount

proc nestedPermissionShapeNode(typeNode: NimNode): bool =
  let scopeType = objectFieldTypeNode(typeNode, "scope")
  let allowedType = objectFieldTypeNode(typeNode, "allowed")
  scopeType.kind != nnkEmpty and allowedType.kind != nnkEmpty and
    scopeType.typeKind in {ntyString} and allowedType.typeKind in {ntyBool}

proc nestedCommentShapeNode(typeNode: NimNode): bool =
  let authorType = objectFieldTypeNode(typeNode, "author")
  let messageType = objectFieldTypeNode(typeNode, "message")
  let scoreType = objectFieldTypeNode(typeNode, "score")
  authorType.kind != nnkEmpty and messageType.kind != nnkEmpty and scoreType.kind != nnkEmpty and
    authorType.typeKind in {ntyString} and messageType.typeKind in {ntyString} and
    scoreType.typeKind in {ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64, ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64}

proc nestedOwnerShapeNode(typeNode: NimNode): bool =
  let idType = objectFieldTypeNode(typeNode, "id")
  let nameType = objectFieldTypeNode(typeNode, "name")
  let permissionsType = objectFieldTypeNode(typeNode, "permissions")
  if idType.kind == nnkEmpty or nameType.kind == nnkEmpty or permissionsType.kind == nnkEmpty:
    return false
  let permissionType = seqElementTypeNode(permissionsType)
  idType.typeKind in {ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64, ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64} and
    nameType.typeKind in {ntyString} and permissionType.kind != nnkEmpty and nestedPermissionShapeNode(permissionType)

proc nestedTaskShapeNode(typeNode: NimNode): bool =
  let idType = objectFieldTypeNode(typeNode, "id")
  let titleType = objectFieldTypeNode(typeNode, "title")
  let completedType = objectFieldTypeNode(typeNode, "completed")
  let tagsType = objectFieldTypeNode(typeNode, "tags")
  let commentsType = objectFieldTypeNode(typeNode, "comments")
  if idType.kind == nnkEmpty or titleType.kind == nnkEmpty or completedType.kind == nnkEmpty or
      tagsType.kind == nnkEmpty or commentsType.kind == nnkEmpty:
    return false
  let tagType = seqElementTypeNode(tagsType)
  let commentType = seqElementTypeNode(commentsType)
  idType.typeKind in {ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64, ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64} and
    titleType.typeKind in {ntyString} and completedType.typeKind in {ntyBool} and
    tagType.kind != nnkEmpty and tagType.typeKind in {ntyString} and
    commentType.kind != nnkEmpty and nestedCommentShapeNode(commentType)

proc nestedProjectStatsShapeNode(typeNode: NimNode): bool =
  let openType = objectFieldTypeNode(typeNode, "openCount")
  let closedType = objectFieldTypeNode(typeNode, "closedCount")
  let velocityType = objectFieldTypeNode(typeNode, "velocity")
  openType.kind != nnkEmpty and closedType.kind != nnkEmpty and velocityType.kind != nnkEmpty and
    openType.typeKind in {ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64, ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64} and
    closedType.typeKind in {ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64, ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64} and
    velocityType.typeKind in {ntyFloat, ntyFloat32, ntyFloat64}

proc nestedProjectShapeNode(typeNode: NimNode): bool =
  let projectIdType = objectFieldTypeNode(typeNode, "projectId")
  let nameType = objectFieldTypeNode(typeNode, "name")
  let activeType = objectFieldTypeNode(typeNode, "active")
  let ownersType = objectFieldTypeNode(typeNode, "owners")
  let tasksType = objectFieldTypeNode(typeNode, "tasks")
  let statsType = objectFieldTypeNode(typeNode, "stats")
  if projectIdType.kind == nnkEmpty or nameType.kind == nnkEmpty or activeType.kind == nnkEmpty or
      ownersType.kind == nnkEmpty or tasksType.kind == nnkEmpty or statsType.kind == nnkEmpty:
    return false
  let ownerType = seqElementTypeNode(ownersType)
  let taskType = seqElementTypeNode(tasksType)
  projectIdType.typeKind in {ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64, ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64} and
    nameType.typeKind in {ntyString} and activeType.typeKind in {ntyBool} and
    ownerType.kind != nnkEmpty and nestedOwnerShapeNode(ownerType) and
    taskType.kind != nnkEmpty and nestedTaskShapeNode(taskType) and
    nestedProjectStatsShapeNode(statsType)

proc nestedProjectEnvelopeShapeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  let projectsType = objectFieldTypeNode(concrete, "projects")
  let metaType = objectFieldTypeNode(concrete, "meta")
  if projectsType.kind == nnkEmpty or metaType.kind == nnkEmpty:
    return false
  let projectType = seqElementTypeNode(projectsType)
  if projectType.kind == nnkEmpty or not nestedProjectShapeNode(projectType):
    return false
  let pageType = objectFieldTypeNode(metaType, "page")
  let countType = objectFieldTypeNode(metaType, "count")
  pageType.kind != nnkEmpty and countType.kind != nnkEmpty and
    pageType.typeKind in {ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64, ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64} and
    countType.typeKind in {ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64, ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64}

macro decodeNativeMediumEnvelope(typeNode: typedesc, dataExpr: typed, lenExpr: typed): untyped =
  if not mediumTodoEnvelopeShapeNode(typeNode):
    return quote do:
      let jsonText = copyCString(`dataExpr`, `lenExpr`)
      let doc = parse(jsonText)
      decodeJson(doc.root(), `typeNode`)

  let concrete = unwrapTypedescNode(typeNode)
  let rootRecList = supportedObjectRecList(concrete)
  var todoType = newEmptyNode()
  for child in rootRecList:
    if child.kind != nnkIdentDefs or child.len < 3:
      continue
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind == nnkIdent and $fieldNode == "todos":
        todoType = child[^2].getTypeInst[1]

  let envelopeSym = genSym(nskVar, "envelope")
  let decodedSym = genSym(nskVar, "decoded")
  let todoCountSym = genSym(nskLet, "todoCount")
  let idxSym = genSym(nskForVar, "idx")
  let todoPtrSym = genSym(nskLet, "todoPtr")
  let rawTodosSym = genSym(nskLet, "rawTodos")
  let rawTodoSym = genSym(nskLet, "rawTodo")
  result = quote do:
    block:
      var `envelopeSym`: CMediumTodoEnvelope
      try:
        ensureSuccess(simdjsonExtractMediumTodoEnvelope(`dataExpr`, `lenExpr`, addr `envelopeSym`))
        var `decodedSym`: `typeNode`
        let `todoCountSym` = csizeToInt(`envelopeSym`.todos_len, "simdjson todos array")
        `decodedSym`.todos = newSeq[`todoType`](`todoCountSym`)
        let `rawTodosSym` = cast[ptr UncheckedArray[CMediumTodoItem]](`envelopeSym`.todos)
        for `idxSym` in 0 ..< `todoCountSym`:
          let `rawTodoSym` = `rawTodosSym`[`idxSym`]
          let `todoPtrSym` = addr `decodedSym`.todos[`idxSym`]
          `todoPtrSym`[].id = checkedSignedJsonInt[type(`todoPtrSym`[].id)](`rawTodoSym`.id)
          `todoPtrSym`[].title = copyCString(`rawTodoSym`.title_data, `rawTodoSym`.title_len)
          `todoPtrSym`[].completed = `rawTodoSym`.completed
        `decodedSym`.meta.page = checkedSignedJsonInt[type(`decodedSym`.meta.page)](`envelopeSym`.page)
        `decodedSym`.meta.count = checkedSignedJsonInt[type(`decodedSym`.meta.count)](`envelopeSym`.count)
        `decodedSym`
      finally:
        simdjsonMediumTodoEnvelopeRelease(addr `envelopeSym`)

macro decodeNativeNestedProjectEnvelope(typeNode: typedesc, dataExpr: typed, lenExpr: typed): untyped {.used.} =
  if not nestedProjectEnvelopeShapeNode(typeNode):
    return quote do:
      let jsonText = copyCString(`dataExpr`, `lenExpr`)
      let doc = parse(jsonText)
      decodeJson(doc.root(), `typeNode`)

  let concrete = unwrapTypedescNode(typeNode)
  let projectType = seqElementTypeNode(objectFieldTypeNode(concrete, "projects"))
  let ownerType = seqElementTypeNode(objectFieldTypeNode(projectType, "owners"))
  let permissionType = seqElementTypeNode(objectFieldTypeNode(ownerType, "permissions"))
  let taskType = seqElementTypeNode(objectFieldTypeNode(projectType, "tasks"))
  let commentType = seqElementTypeNode(objectFieldTypeNode(taskType, "comments"))
  let envelopeSym = genSym(nskVar, "nestedEnvelope")
  let decodedSym = genSym(nskVar, "decoded")
  let projectCountSym = genSym(nskLet, "projectCount")
  let ownerCountSym = genSym(nskLet, "ownerCount")
  let permissionCountSym = genSym(nskLet, "permissionCount")
  let taskCountSym = genSym(nskLet, "taskCount")
  let tagCountSym = genSym(nskLet, "tagCount")
  let commentCountSym = genSym(nskLet, "commentCount")
  let projectsArrSym = genSym(nskLet, "projectsArr")
  let projectIdxSym = genSym(nskForVar, "projectIdx")
  let rawProjectSym = genSym(nskLet, "rawProject")
  let projectPtrSym = genSym(nskLet, "projectPtr")
  let ownersArrSym = genSym(nskLet, "ownersArr")
  let ownerIdxSym = genSym(nskForVar, "ownerIdx")
  let rawOwnerSym = genSym(nskLet, "rawOwner")
  let ownerPtrSym = genSym(nskLet, "ownerPtr")
  let permissionsArrSym = genSym(nskLet, "permissionsArr")
  let permissionIdxSym = genSym(nskForVar, "permissionIdx")
  let rawPermissionSym = genSym(nskLet, "rawPermission")
  let permissionPtrSym = genSym(nskLet, "permissionPtr")
  let tasksArrSym = genSym(nskLet, "tasksArr")
  let taskIdxSym = genSym(nskForVar, "taskIdx")
  let rawTaskSym = genSym(nskLet, "rawTask")
  let taskPtrSym = genSym(nskLet, "taskPtr")
  let tagsArrSym = genSym(nskLet, "tagsArr")
  let tagIdxSym = genSym(nskForVar, "tagIdx")
  let rawTagSym = genSym(nskLet, "rawTag")
  let commentsArrSym = genSym(nskLet, "commentsArr")
  let commentIdxSym = genSym(nskForVar, "commentIdx")
  let rawCommentSym = genSym(nskLet, "rawComment")
  let commentPtrSym = genSym(nskLet, "commentPtr")

  quote do:
    block:
      var `envelopeSym`: CNestedProjectEnvelope
      try:
        ensureSuccess(simdjsonExtractNestedProjectEnvelope(`dataExpr`, `lenExpr`, addr `envelopeSym`))
        var `decodedSym`: `typeNode`
        let `projectCountSym` = csizeToInt(`envelopeSym`.projects_len, "simdjson projects array")
        `decodedSym`.projects = newSeq[`projectType`](`projectCountSym`)
        let `projectsArrSym` = cast[ptr UncheckedArray[CNestedProjectItem]](`envelopeSym`.projects)
        for `projectIdxSym` in 0 ..< `projectCountSym`:
          let `rawProjectSym` = `projectsArrSym`[`projectIdxSym`]
          let `projectPtrSym` = addr `decodedSym`.projects[`projectIdxSym`]
          `projectPtrSym`[].projectId = checkedSignedJsonInt[type(`projectPtrSym`[].projectId)](`rawProjectSym`.project_id)
          `projectPtrSym`[].name = copyCString(`rawProjectSym`.name_data, `rawProjectSym`.name_len)
          `projectPtrSym`[].active = `rawProjectSym`.active
          let `ownerCountSym` = csizeToInt(`rawProjectSym`.owners_len, "simdjson owners array")
          `projectPtrSym`[].owners = newSeq[`ownerType`](`ownerCountSym`)
          let `ownersArrSym` = cast[ptr UncheckedArray[CNestedOwnerItem]](`rawProjectSym`.owners)
          for `ownerIdxSym` in 0 ..< `ownerCountSym`:
            let `rawOwnerSym` = `ownersArrSym`[`ownerIdxSym`]
            let `ownerPtrSym` = addr `projectPtrSym`[].owners[`ownerIdxSym`]
            `ownerPtrSym`[].id = checkedSignedJsonInt[type(`ownerPtrSym`[].id)](`rawOwnerSym`.id)
            `ownerPtrSym`[].name = copyCString(`rawOwnerSym`.name_data, `rawOwnerSym`.name_len)
            let `permissionCountSym` = csizeToInt(`rawOwnerSym`.permissions_len, "simdjson permissions array")
            `ownerPtrSym`[].permissions = newSeq[`permissionType`](`permissionCountSym`)
            let `permissionsArrSym` = cast[ptr UncheckedArray[CNestedPermissionItem]](`rawOwnerSym`.permissions)
            for `permissionIdxSym` in 0 ..< `permissionCountSym`:
              let `rawPermissionSym` = `permissionsArrSym`[`permissionIdxSym`]
              let `permissionPtrSym` = addr `ownerPtrSym`[].permissions[`permissionIdxSym`]
              `permissionPtrSym`[].scope = copyCString(`rawPermissionSym`.scope_data, `rawPermissionSym`.scope_len)
              `permissionPtrSym`[].allowed = `rawPermissionSym`.allowed
          let `taskCountSym` = csizeToInt(`rawProjectSym`.tasks_len, "simdjson tasks array")
          `projectPtrSym`[].tasks = newSeq[`taskType`](`taskCountSym`)
          let `tasksArrSym` = cast[ptr UncheckedArray[CNestedTaskItem]](`rawProjectSym`.tasks)
          for `taskIdxSym` in 0 ..< `taskCountSym`:
            let `rawTaskSym` = `tasksArrSym`[`taskIdxSym`]
            let `taskPtrSym` = addr `projectPtrSym`[].tasks[`taskIdxSym`]
            `taskPtrSym`[].id = checkedSignedJsonInt[type(`taskPtrSym`[].id)](`rawTaskSym`.id)
            `taskPtrSym`[].title = copyCString(`rawTaskSym`.title_data, `rawTaskSym`.title_len)
            `taskPtrSym`[].completed = `rawTaskSym`.completed
            let `tagCountSym` = csizeToInt(`rawTaskSym`.tags_len, "simdjson tags array")
            `taskPtrSym`[].tags = newSeq[string](`tagCountSym`)
            let `tagsArrSym` = cast[ptr UncheckedArray[CNestedStringItem]](`rawTaskSym`.tags)
            for `tagIdxSym` in 0 ..< `tagCountSym`:
              let `rawTagSym` = `tagsArrSym`[`tagIdxSym`]
              `taskPtrSym`[].tags[`tagIdxSym`] = copyCString(`rawTagSym`.data, `rawTagSym`.len)
            let `commentCountSym` = csizeToInt(`rawTaskSym`.comments_len, "simdjson comments array")
            `taskPtrSym`[].comments = newSeq[`commentType`](`commentCountSym`)
            let `commentsArrSym` = cast[ptr UncheckedArray[CNestedCommentItem]](`rawTaskSym`.comments)
            for `commentIdxSym` in 0 ..< `commentCountSym`:
              let `rawCommentSym` = `commentsArrSym`[`commentIdxSym`]
              let `commentPtrSym` = addr `taskPtrSym`[].comments[`commentIdxSym`]
              `commentPtrSym`[].author = copyCString(`rawCommentSym`.author_data, `rawCommentSym`.author_len)
              `commentPtrSym`[].message = copyCString(`rawCommentSym`.message_data, `rawCommentSym`.message_len)
              `commentPtrSym`[].score = checkedSignedJsonInt[type(`commentPtrSym`[].score)](`rawCommentSym`.score)
          `projectPtrSym`[].stats.openCount = checkedSignedJsonInt[type(`projectPtrSym`[].stats.openCount)](`rawProjectSym`.stats.open_count)
          `projectPtrSym`[].stats.closedCount = checkedSignedJsonInt[type(`projectPtrSym`[].stats.closedCount)](`rawProjectSym`.stats.closed_count)
          `projectPtrSym`[].stats.velocity = type(`projectPtrSym`[].stats.velocity)(`rawProjectSym`.stats.velocity)
        `decodedSym`.meta.page = checkedSignedJsonInt[type(`decodedSym`.meta.page)](`envelopeSym`.page)
        `decodedSym`.meta.count = checkedSignedJsonInt[type(`decodedSym`.meta.count)](`envelopeSym`.count)
        `decodedSym`
      finally:
        simdjsonNestedProjectEnvelopeRelease(addr `envelopeSym`)

macro decodeOndemandObjectFast(typeNode: typedesc, dataExpr: typed, lenExpr: typed): untyped =
  let recList = supportedObjectRecList(typeNode)
  if recList.kind != nnkRecList or not ondemandSupportedTypeNode(typeNode):
    return quote do:
      let jsonText = copyCString(`dataExpr`, `lenExpr`)
      let doc = parse(jsonText)
      decodeJson(doc.root(), `typeNode`)

  let entriesSym = genSym(nskVar, "entries")
  let decodedSym = genSym(nskVar, "decoded")
  let initStmts = newStmtList()
  let assignStmts = newStmtList()
  var fieldCount = 0

  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return quote do:
        let jsonText = copyCString(`dataExpr`, `lenExpr`)
        let doc = parse(jsonText)
        decodeJson(doc.root(), `typeNode`)
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind != nnkIdent:
        return quote do:
          let jsonText = copyCString(`dataExpr`, `lenExpr`)
          let doc = parse(jsonText)
          decodeJson(doc.root(), `typeNode`)
      let fieldNameLit = newLit($fieldNode)
      let entryIndex = newLit(fieldCount)
      let fieldAccess = nnkDotExpr.newTree(decodedSym, fieldNode)
      initStmts.add quote do:
        `entriesSym`[`entryIndex`].key = `fieldNameLit`.cstring
        `entriesSym`[`entryIndex`].key_len = `fieldNameLit`.len.csize_t
      assignStmts.add quote do:
        if `entriesSym`[`entryIndex`].found_kind >= 0:
          `fieldAccess` = decodeOndemandData(
            `entriesSym`[`entryIndex`].data,
            `entriesSym`[`entryIndex`].data_len,
            `entriesSym`[`entryIndex`].found_kind,
            `entriesSym`[`entryIndex`].bool_value,
            `entriesSym`[`entryIndex`].int64_value,
            `entriesSym`[`entryIndex`].uint64_value,
            `entriesSym`[`entryIndex`].double_value,
            type(`fieldAccess`)
          )
      inc fieldCount

  let fieldCountLit = newLit(fieldCount)
  result = quote do:
    block:
      var `entriesSym` = newSeq[COndemandEntry](`fieldCountLit`)
      `initStmts`
      try:
        if `fieldCountLit` > 0:
          ensureSuccess(simdjsonOndemandProjectObject(`dataExpr`, `lenExpr`, addr `entriesSym`[0], `fieldCountLit`.csize_t))
        var `decodedSym`: `typeNode`
        `assignStmts`
        `decodedSym`
      finally:
        if `fieldCountLit` > 0:
          simdjsonOndemandEntriesRelease(addr `entriesSym`[0], `fieldCountLit`.csize_t)

macro decodeGeneratedDirectObject(typeNode: typedesc, dataExpr: typed, lenExpr: typed): untyped =
  let recList = supportedObjectRecList(typeNode)
  if recList.kind != nnkRecList or not directDecodeSupportedTypeNode(typeNode):
    return quote do:
      decodeNativePlanJson(`typeNode`, `dataExpr`, `lenExpr`)

  let entriesSym = genSym(nskVar, "entries")
  let decodedSym = genSym(nskVar, "decoded")
  let initStmts = newStmtList()
  let assignStmts = newStmtList()
  var fieldCount = 0
  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return quote do:
        decodeNativePlanJson(`typeNode`, `dataExpr`, `lenExpr`)
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind != nnkIdent:
        return quote do:
          decodeNativePlanJson(`typeNode`, `dataExpr`, `lenExpr`)
      let fieldNameLit = newLit($fieldNode)
      let entryIndex = newLit(fieldCount)
      let fieldAccess = nnkDotExpr.newTree(decodedSym, fieldNode)
      initStmts.add quote do:
        `entriesSym`[`entryIndex`].key = `fieldNameLit`.cstring
        `entriesSym`[`entryIndex`].key_len = `fieldNameLit`.len.csize_t
      assignStmts.add quote do:
        if `entriesSym`[`entryIndex`].found_kind >= 0:
          `fieldAccess` = decodeGeneratedDirectValue(
            `entriesSym`[`entryIndex`].data,
            `entriesSym`[`entryIndex`].data_len,
            `entriesSym`[`entryIndex`].found_kind,
            `entriesSym`[`entryIndex`].bool_value,
            `entriesSym`[`entryIndex`].int64_value,
            `entriesSym`[`entryIndex`].uint64_value,
            `entriesSym`[`entryIndex`].double_value,
            type(`fieldAccess`)
          )
      inc fieldCount
  let fieldCountLit = newLit(fieldCount)
  result = quote do:
    block:
      var `entriesSym` = newSeq[COndemandEntry](`fieldCountLit`)
      `initStmts`
      try:
        if `fieldCountLit` > 0:
          ensureSuccess(simdjsonOndemandProjectObject(`dataExpr`, `lenExpr`, addr `entriesSym`[0], `fieldCountLit`.csize_t))
        var `decodedSym`: `typeNode`
        `assignStmts`
        `decodedSym`
      finally:
        if `fieldCountLit` > 0:
          simdjsonOndemandEntriesRelease(addr `entriesSym`[0], `fieldCountLit`.csize_t)

proc decodeOndemandObjectJson[T: object](data: cstring, len: csize_t, _: typedesc[T]): T =
  decodeOndemandObjectFast(T, data, len)

proc decodeGeneratedDirectObjectJson[T: object](data: cstring, len: csize_t, _: typedesc[T]): T =
  decodeGeneratedDirectObject(T, data, len)

macro decodeGeneratedDirectSeqObject(typeNode: typedesc, dataExpr: typed, lenExpr: typed): untyped =
  let recList = supportedObjectRecList(typeNode)
  if recList.kind != nnkRecList:
    return quote do:
      let jsonText = copyCString(`dataExpr`, `lenExpr`)
      let doc = parse(jsonText)
      decodeJson(doc.root(), seq[`typeNode`])

  let entriesSym = genSym(nskVar, "entries")
  let decodedSym = genSym(nskVar, "decoded")
  let itemsLenSym = genSym(nskVar, "itemsLen")
  let itemIndexSym = genSym(nskForVar, "itemIndex")
  let baseIndexSym = genSym(nskLet, "baseIndex")
  let initStmts = newStmtList()
  let assignStmts = newStmtList()
  var fieldCount = 0

  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return quote do:
        let jsonText = copyCString(`dataExpr`, `lenExpr`)
        let doc = parse(jsonText)
        decodeJson(doc.root(), seq[`typeNode`])
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind != nnkIdent:
        return quote do:
          let jsonText = copyCString(`dataExpr`, `lenExpr`)
          let doc = parse(jsonText)
          decodeJson(doc.root(), seq[`typeNode`])
      let fieldNameLit = newLit($fieldNode)
      let entryIndex = newLit(fieldCount)
      let fieldAccess = nnkDotExpr.newTree(nnkBracketExpr.newTree(decodedSym, itemIndexSym), fieldNode)
      initStmts.add quote do:
        `entriesSym`[`baseIndexSym` + `entryIndex`].key = `fieldNameLit`.cstring
        `entriesSym`[`baseIndexSym` + `entryIndex`].key_len = `fieldNameLit`.len.csize_t
      assignStmts.add quote do:
        if `entriesSym`[`baseIndexSym` + `entryIndex`].found_kind >= 0:
          `fieldAccess` = decodeGeneratedDirectValue(
            `entriesSym`[`baseIndexSym` + `entryIndex`].data,
            `entriesSym`[`baseIndexSym` + `entryIndex`].data_len,
            `entriesSym`[`baseIndexSym` + `entryIndex`].found_kind,
            `entriesSym`[`baseIndexSym` + `entryIndex`].bool_value,
            `entriesSym`[`baseIndexSym` + `entryIndex`].int64_value,
            `entriesSym`[`baseIndexSym` + `entryIndex`].uint64_value,
            `entriesSym`[`baseIndexSym` + `entryIndex`].double_value,
            type(`fieldAccess`)
          )
      inc fieldCount

  let fieldCountLit = newLit(fieldCount)
  let itemCountSym = genSym(nskLet, "itemCount")
  result = quote do:
    block:
      var `itemsLenSym`: csize_t
      ensureSuccess(simdjsonOndemandArrayLength(`dataExpr`, `lenExpr`, addr `itemsLenSym`))
      let `itemCountSym` = csizeToInt(`itemsLenSym`, "simdjson array")
      var `decodedSym` = newSeq[`typeNode`](`itemCountSym`)
      if `itemCountSym` == 0:
        `decodedSym`
      else:
        let totalEntries = checkedJsonMul(`itemCountSym`, `fieldCountLit`, "simdjson array is too large")
        var `entriesSym` = newSeq[COndemandEntry](totalEntries)
        for `itemIndexSym` in 0 ..< `itemCountSym`:
          let `baseIndexSym` = `itemIndexSym` * `fieldCountLit`
          `initStmts`
        try:
          ensureSuccess(simdjsonOndemandProjectArrayObjects(
            `dataExpr`,
            `lenExpr`,
            addr `entriesSym`[0],
            `itemsLenSym`,
            `fieldCountLit`.csize_t
          ))
          for `itemIndexSym` in 0 ..< `itemCountSym`:
            let `baseIndexSym` = `itemIndexSym` * `fieldCountLit`
            `assignStmts`
          `decodedSym`
        finally:
          simdjsonOndemandEntriesRelease(addr `entriesSym`[0], totalEntries.csize_t)

proc decodeGeneratedDirectSeqObjectJson[T: object](data: cstring, len: csize_t, _: typedesc[T]): seq[T] =
  decodeGeneratedDirectSeqObject(T, data, len)

proc decodeOndemandJson[T](data: cstring, len: csize_t, _: typedesc[ref T]): ref T =
  var root: COndemandValue
  try:
    ensureSuccess(simdjsonOndemandCapture(data, len, addr root))
    if root.found_kind < 0 or kindFromInt(root.found_kind) == jkNull:
      return nil
    new(result)
    result[] = decodeOndemandData(root.data, root.data_len, root.found_kind, root.bool_value, root.int64_value, root.uint64_value, root.double_value, T)
  finally:
    simdjsonOndemandValueRelease(addr root)

proc decodeOndemandJson[T](data: cstring, len: csize_t, _: typedesc[T]): T =
  when jsonDecodeTier(T) == jdtNativePlan:
    when isMediumTodoEnvelopeShape(T):
      decodeNativeMediumEnvelope(T, data, len)
    elif isNestedProjectEnvelopeShape(T):
      decodeNativeNestedProjectEnvelope(T, data, len)
    elif directDecodeSupported(T):
      decodeGeneratedDirectObjectJson(data, len, T)
    else:
      decodeNativePlanJson(T, data, len)
  elif jsonDecodeTier(T) == jdtOndemandLeaf:
    when T is object:
      decodeOndemandObjectJson(data, len, T)
    else:
      var root: COndemandValue
      try:
        ensureSuccess(simdjsonOndemandCapture(data, len, addr root))
        decodeOndemandData(root.data, root.data_len, root.found_kind, root.bool_value, root.int64_value, root.uint64_value, root.double_value, T)
      finally:
        simdjsonOndemandValueRelease(addr root)
  else:
    let jsonText = copyCString(data, len)
    let doc = parse(jsonText)
    decodeJson(doc.root(), T)

proc tryAssignField(field: var string, cursor: ObjectCursor, key: string): bool {.inline.} =
  var view: BorrowedString
  if not cursor.tryGetStrView(key, view):
    return false
  field = view.toString()
  true

proc tryAssignField(field: var BorrowedString, cursor: ObjectCursor, key: string): bool {.inline.} =
  cursor.tryGetStrView(key, field)

proc tryAssignField(field: var bool, cursor: ObjectCursor, key: string): bool {.inline.} =
  cursor.tryGetBool(key, field)

proc tryAssignField[T: SomeSignedInt](field: var T, cursor: ObjectCursor, key: string): bool {.inline.} =
  var signedValue: int64
  if cursor.tryGetInt64(key, signedValue):
    if signedValue < int64(low(T)) or signedValue > int64(high(T)):
      raise newException(ValueError, "JSON integer out of range for target type")
    field = T(signedValue)
    return true
  var unsignedValue: uint64
  if cursor.tryGetUint64(key, unsignedValue):
    if unsignedValue > uint64(high(T)):
      raise newException(ValueError, "JSON integer out of range for target type")
    field = T(unsignedValue)
    return true
  false

proc tryAssignField[T: SomeUnsignedInt](field: var T, cursor: ObjectCursor, key: string): bool {.inline.} =
  var unsignedValue: uint64
  if cursor.tryGetUint64(key, unsignedValue):
    if unsignedValue > uint64(high(T)):
      raise newException(ValueError, "JSON integer out of range for target type")
    field = T(unsignedValue)
    return true
  var signedValue: int64
  if cursor.tryGetInt64(key, signedValue):
    if signedValue < 0 or uint64(signedValue) > uint64(high(T)):
      raise newException(ValueError, "JSON integer out of range for target type")
    field = T(signedValue)
    return true
  false

proc tryAssignField[T: SomeFloat](field: var T, cursor: ObjectCursor, key: string): bool {.inline.} =
  let child = cursor.tryGet(key)
  if child.isNil:
    return false
  field = decodeJson(child, T)
  true

proc tryAssignField(field: var char, cursor: ObjectCursor, key: string): bool {.inline.} =
  var view: BorrowedString
  if not cursor.tryGetStrView(key, view):
    return false
  let raw = view.toString()
  if raw.len != 1:
    raise newException(ValueError, "JSON string must have length 1 to decode into char")
  field = raw[0]
  true

proc tryAssignField[T: enum](field: var T, cursor: ObjectCursor, key: string): bool {.inline.} =
  var view: BorrowedString
  if not cursor.tryGetStrView(key, view):
    return false
  let raw = view.toString()
  for candidate in low(T) .. high(T):
    if $candidate == raw:
      field = candidate
      return true
  raise newException(ValueError, "unknown enum value: " & raw)

proc tryAssignField[T](field: var Option[T], cursor: ObjectCursor, key: string): bool {.inline.} =
  let child = cursor.tryGet(key)
  if child.isNil:
    return false
  if child.isNull:
    field = none(T)
  else:
    field = some(decodeJson(child, T))
  true

proc tryAssignField[T](field: var seq[T], cursor: ObjectCursor, key: string): bool =
  var items: ArrayCursor
  if not cursor.tryGetArrayCursor(key, items):
    return false
  let handles = collectArrayHandles(items)
  let itemsLen = handles.len
  field = newSeq[T](itemsLen)
  for i in 0 ..< itemsLen:
    field[i] = decodeJson(newValue(items.requireStorage(), handles[i]), T)
  true

proc tryAssignField[T, N](field: var array[N, T], cursor: ObjectCursor, key: string): bool =
  var items: ArrayCursor
  if not cursor.tryGetArrayCursor(key, items):
    return false
  let handles = collectArrayHandles(items)
  let itemsLen = handles.len
  if itemsLen != field.len:
    raise newException(ValueError, "JSON array length does not match target array size")
  for i in 0 .. high(field):
    field[i] = decodeJson(newValue(items.requireStorage(), handles[i]), T)
  true

proc tryAssignField[T: object](field: var T, cursor: ObjectCursor, key: string): bool {.inline.} =
  var child: ObjectCursor
  if not cursor.tryGetObjectCursor(key, child):
    return false
  field = decodeJson(child, T)
  true

proc tryAssignField[T](field: var ref T, cursor: ObjectCursor, key: string): bool =
  let child = cursor.tryGet(key)
  if child.isNil:
    return false
  if child.isNull:
    field = nil
  else:
    new(field)
    field[] = decodeJson(child, T)
  true

macro decodeJsonObjectFast(typeNode: typedesc, cursorExpr: typed): untyped =
  let recList = supportedObjectRecList(typeNode)
  let decodedSym = genSym(nskVar, "decoded")

  template fallback(): untyped =
    quote do:
      block:
        var `decodedSym`: `typeNode`
        for fieldName, field in fieldPairs(`decodedSym`):
          discard tryAssignField(field, `cursorExpr`, fieldName)
        `decodedSym`

  if recList.kind != nnkRecList:
    return fallback()

  let assignStmts = newStmtList()
  for child in recList:
    if child.kind != nnkIdentDefs or child.len < 3:
      return fallback()
    for index in 0 ..< child.len - 2:
      var fieldNode = child[index]
      if fieldNode.kind == nnkPostfix and fieldNode.len == 2:
        fieldNode = fieldNode[1]
      if fieldNode.kind != nnkIdent:
        return fallback()
      let fieldAccess = nnkDotExpr.newTree(decodedSym, fieldNode)
      let fieldNameLit = newLit($fieldNode)
      assignStmts.add(
        quote do:
          discard tryAssignField(`fieldAccess`, `cursorExpr`, `fieldNameLit`)
      )

  result = quote do:
    block:
      var `decodedSym`: `typeNode`
      `assignStmts`
      `decodedSym`

proc decodeJson[T: object](cursor: ObjectCursor, _: typedesc[T]): T =
  decodeJsonObjectFast(T, cursor)

proc decodeJson[T: object](value: Value, _: typedesc[T]): T =
  decodeJson(value.objectCursor(), T)

proc decodeJson[T](value: Value, _: typedesc[ref T]): ref T =
  if value.isNil or value.isNull:
    return nil
  new(result)
  result[] = decodeJson(value, T)

proc decodeJson[T: object](value: Value, _: typedesc[ref T]): ref T =
  if value.isNil or value.isNull:
    return nil
  new(result)
  result[] = decodeJson(value, T)

## Serializes ``value`` to a JSON string using ``codec``.
proc serialize*[T](codec: SimdJsonCodec, value: T): string =
  discard codec
  result = newStringOfCap(initialJsonCapacity(value))
  appendJsonValue(result, value)

## Serializes ``value`` to JSON bytes using ``codec``.
proc serializeToBytes*[T](codec: SimdJsonCodec, value: T): seq[byte] {.inline.} =
  copyStringToBytes(codec.serialize(value))

## Serializes ``value`` to JSON and writes it to ``path`` using ``codec``.
proc serializeToFile*[T](codec: SimdJsonCodec, path: string, value: T) =
  writeFile(path, codec.serialize(value))

## Serializes ``value`` to JSON and writes it to ``stream`` using ``codec``.
proc serializeToStream*[T](codec: SimdJsonCodec, stream: Stream, value: T) =
  requireStream(stream)
  stream.write(codec.serialize(value))

## Parses the JSON string ``json`` into a value of type ``T`` using ``codec``.
proc deserialize*[T](codec: SimdJsonCodec, json: string, _: typedesc[T]): T =
  discard codec
  decodeOndemandJson(json.cstring, json.len.csize_t, T)

## Parses the JSON bytes ``data`` into a value of type ``T`` using ``codec``.
proc deserialize*[T](codec: SimdJsonCodec, data: openArray[byte], _: typedesc[T]): T {.inline.} =
  codec.deserialize(copyBytesToString(data), T)

## Reads ``path`` and parses the JSON file into a value of type ``T`` using ``codec``.
proc deserializeFile*[T](codec: SimdJsonCodec, path: string, _: typedesc[T]): T {.inline.} =
  codec.deserialize(readFile(path), T)

## Reads ``stream`` and parses the JSON data into a value of type ``T`` using ``codec``.
proc deserializeStream*[T](codec: SimdJsonCodec, stream: Stream, _: typedesc[T]): T =
  requireStream(stream)
  codec.deserialize(stream.readAll(), T)

## Parses the JSON string ``json`` into ``T`` using ``codec``; returns ``none`` on parse errors.
proc tryDeserialize*[T](codec: SimdJsonCodec, json: string, _: typedesc[T]): Option[T] =
  try:
    some(codec.deserialize(json, T))
  except CatchableError:
    none(T)

## Parses the JSON bytes ``data`` into ``T`` using ``codec``; returns ``none`` on parse errors.
proc tryDeserialize*[T](codec: SimdJsonCodec, data: openArray[byte], _: typedesc[T]): Option[T] {.inline.} =
  codec.tryDeserialize(copyBytesToString(data), T)

## Parses the JSON file at ``path`` into ``T`` using ``codec``; returns ``none`` on parse errors.
proc tryDeserializeFile*[T](codec: SimdJsonCodec, path: string, _: typedesc[T]): Option[T] =
  try:
    some(codec.deserializeFile(path, T))
  except CatchableError:
    none(T)

## Parses the JSON data in ``stream`` into ``T`` using ``codec``; returns ``none`` on parse errors.
proc tryDeserializeStream*[T](codec: SimdJsonCodec, stream: Stream, _: typedesc[T]): Option[T] =
  try:
    some(codec.deserializeStream(stream, T))
  except CatchableError:
    none(T)

## Parses the JSON string ``json`` into ``T`` using ``codec``; returns ``default`` on parse errors.
proc deserializeOr*[T](codec: SimdJsonCodec, json: string, _: typedesc[T], default: T): T =
  try:
    codec.deserialize(json, T)
  except CatchableError:
    default

## Parses the JSON bytes ``data`` into ``T`` using ``codec``; returns ``default`` on parse errors.
proc deserializeOr*[T](codec: SimdJsonCodec, data: openArray[byte], _: typedesc[T], default: T): T {.inline.} =
  codec.deserializeOr(copyBytesToString(data), T, default)

## Parses the JSON file at ``path`` into ``T`` using ``codec``; returns ``default`` on parse errors.
proc deserializeFileOr*[T](codec: SimdJsonCodec, path: string, _: typedesc[T], default: T): T =
  try:
    codec.deserializeFile(path, T)
  except CatchableError:
    default

## Parses the JSON data in ``stream`` into ``T`` using ``codec``; returns ``default`` on parse errors.
proc deserializeStreamOr*[T](codec: SimdJsonCodec, stream: Stream, _: typedesc[T], default: T): T =
  try:
    codec.deserializeStream(stream, T)
  except CatchableError:
    default

## Serializes ``value`` to a JSON string using the default codec.
proc serialize*[T](value: T): string =
  defaultCodec().serialize(value)

## Serializes ``value`` to JSON bytes using the default codec.
proc serializeToBytes*[T](value: T): seq[byte] {.inline.} =
  defaultCodec().serializeToBytes(value)

## Serializes ``value`` to JSON and writes it to ``path`` using the default codec.
proc serializeToFile*[T](path: string, value: T) {.inline.} =
  defaultCodec().serializeToFile(path, value)

## Serializes ``value`` to JSON and writes it to ``stream`` using the default codec.
proc serializeToStream*[T](stream: Stream, value: T) {.inline.} =
  defaultCodec().serializeToStream(stream, value)

## Parses the JSON string ``json`` into a value of type ``T`` using the default codec.
proc deserialize*[T](json: string, _: typedesc[T]): T =
  defaultCodec().deserialize(json, T)

## Parses the JSON bytes ``data`` into a value of type ``T`` using the default codec.
proc deserialize*[T](data: openArray[byte], _: typedesc[T]): T {.inline.} =
  defaultCodec().deserialize(data, T)

## Reads ``path`` and parses the JSON file into a value of type ``T`` using the default codec.
proc deserializeFile*[T](path: string, _: typedesc[T]): T {.inline.} =
  defaultCodec().deserializeFile(path, T)

## Reads ``stream`` and parses the JSON data into a value of type ``T`` using the default codec.
proc deserializeStream*[T](stream: Stream, _: typedesc[T]): T {.inline.} =
  defaultCodec().deserializeStream(stream, T)

## Parses the JSON string ``json`` into ``T`` using the default codec; returns ``none`` on parse errors.
proc tryDeserialize*[T](json: string, _: typedesc[T]): Option[T] =
  defaultCodec().tryDeserialize(json, T)

## Parses the JSON bytes ``data`` into ``T`` using the default codec; returns ``none`` on parse errors.
proc tryDeserialize*[T](data: openArray[byte], _: typedesc[T]): Option[T] {.inline.} =
  defaultCodec().tryDeserialize(data, T)

## Parses the JSON file at ``path`` into ``T`` using the default codec; returns ``none`` on parse errors.
proc tryDeserializeFile*[T](path: string, _: typedesc[T]): Option[T] {.inline.} =
  defaultCodec().tryDeserializeFile(path, T)

## Parses the JSON data in ``stream`` into ``T`` using the default codec; returns ``none`` on parse errors.
proc tryDeserializeStream*[T](stream: Stream, _: typedesc[T]): Option[T] {.inline.} =
  defaultCodec().tryDeserializeStream(stream, T)

## Parses the JSON string ``json`` into ``T`` using the default codec; returns ``default`` on parse errors.
proc deserializeOr*[T](json: string, _: typedesc[T], default: T): T =
  defaultCodec().deserializeOr(json, T, default)

## Parses the JSON bytes ``data`` into ``T`` using the default codec; returns ``default`` on parse errors.
proc deserializeOr*[T](data: openArray[byte], _: typedesc[T], default: T): T {.inline.} =
  defaultCodec().deserializeOr(data, T, default)

## Parses the JSON file at ``path`` into ``T`` using the default codec; returns ``default`` on parse errors.
proc deserializeFileOr*[T](path: string, _: typedesc[T], default: T): T {.inline.} =
  defaultCodec().deserializeFileOr(path, T, default)

## Parses the JSON data in ``stream`` into ``T`` using the default codec; returns ``default`` on parse errors.
proc deserializeStreamOr*[T](stream: Stream, _: typedesc[T], default: T): T {.inline.} =
  defaultCodec().deserializeStreamOr(stream, T, default)
