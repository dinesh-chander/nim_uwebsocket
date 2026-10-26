## Decode-routing predicates for the pure-Nim direct engine.
##
## Historically this module also routed borrowed-string shapes through a
## simdjson C++ backend; that backend was removed. All decoding now runs on
## the pure-Nim direct engine, and borrowed shapes simply get zero-copy
## string views from it.

import macros

import ./borrowed

type
  ## Alias for the pure-Nim ``BorrowedString`` view type.
  BorrowedStringAlias* = borrowed.BorrowedString

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
  if eqIdent(concrete, "BorrowedString") or eqIdent(concrete, "JsonStringView") or eqIdent(concrete, "BorrowedStringAlias"):
    return true
  let typeInst = concrete.getTypeInst
  eqIdent(typeInst, "BorrowedString") or eqIdent(typeInst, "JsonStringView") or eqIdent(typeInst, "BorrowedStringAlias")

proc containsBorrowedStringTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  if isBorrowedStringTypeNode(concrete):
    return true

  let typeInst = concrete.getTypeInst
  if typeInst.kind == nnkBracketExpr:
    if typeInst.len == 2 and (eqIdent(typeInst[0], "seq") or eqIdent(typeInst[0], "ref") or eqIdent(typeInst[0], "Option")):
      return containsBorrowedStringTypeNode(typeInst[1])
    if typeInst.len == 3 and eqIdent(typeInst[0], "array"):
      return containsBorrowedStringTypeNode(typeInst[2])

  let recList = supportedObjectRecList(concrete)
  if recList.kind == nnkRecList:
    for child in recList:
      if child.kind != nnkIdentDefs or child.len < 3:
        return false
      if containsBorrowedStringTypeNode(child[^2]):
        return true
    return false

  false

proc directLeafDecodeTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  if isBorrowedStringTypeNode(concrete):
    return false

  let recList = supportedObjectRecList(concrete)
  if recList.kind == nnkRecList:
    for child in recList:
      if child.kind != nnkIdentDefs or child.len < 3:
        return false
      if not directLeafDecodeTypeNode(child[^2]):
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
  if directLeafDecodeTypeNode(concrete):
    return true

  let recList = supportedObjectRecList(concrete)
  if recList.kind == nnkRecList:
    for child in recList:
      if child.kind != nnkIdentDefs or child.len < 3:
        return false
      let fieldType = unwrapTypedescNode(child[^2])
      if directLeafDecodeTypeNode(fieldType):
        continue
      let fieldInst = fieldType.getTypeInst
      if fieldInst.kind == nnkBracketExpr and fieldInst.len == 2 and eqIdent(fieldInst[0], "seq") and
          directLeafDecodeTypeNode(fieldInst[1]):
        continue
      return false
    return true

  let typeInst = concrete.getTypeInst
  if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "seq"):
    return directLeafDecodeTypeNode(typeInst[1])

  false

proc directNestedDecodeTypeNode(typeNode: NimNode): bool =
  let concrete = unwrapTypedescNode(typeNode)
  if containsBorrowedStringTypeNode(concrete):
    return false
  if not directDecodeSupportedTypeNode(concrete):
    return false
  if directLeafDecodeTypeNode(concrete):
    return false

  let recList = supportedObjectRecList(concrete)
  if recList.kind == nnkRecList:
    return true

  let typeInst = concrete.getTypeInst
  typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "seq") and
    directLeafDecodeTypeNode(typeInst[1])

## True when T contains a borrowed string field and thus decodes with zero-copy string views.
macro borrowedTypedDecodeSupported*(T: typedesc): untyped =
  newLit(containsBorrowedStringTypeNode(T))

macro containsBorrowedString*(T: typedesc): untyped =
  ## Compile-time predicate: does ``T`` (at any nesting depth) declare a
  ## ``BorrowedString`` / ``JsonStringView`` field?
  newLit(containsBorrowedStringTypeNode(T))

## True when T is a flat object of directly decodable leaf fields.
macro directLeafDecodeSupported*(T: typedesc): untyped =
  newLit(directLeafDecodeTypeNode(T) and directDecodeSupportedTypeNode(T))

## True when T is a nested (non-leaf) shape the direct engine can decode.
macro directNestedDecodeSupported*(T: typedesc): untyped =
  newLit(directNestedDecodeTypeNode(T))
