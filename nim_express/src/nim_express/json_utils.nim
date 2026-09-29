## Fast JSON utilities for nim_express using direct_engine (cursor-based,
## SIMD-accelerated serializer) from nim_fastjson.
##
## For low-level DOM/cursor parsing use nim_fastjson/simdjson directly.

import nim_utils/nim_fastjson/direct_engine
import std/options

when defined(singleThread):
  var sharedJsonBuf: string = newStringOfCap(512)
else:
  var sharedJsonBuf {.threadvar.}: string

## Serialize ``obj`` into a thread-local reusable buffer and return it as a borrowed string.
proc serializeReusable*[T](obj: T): lent string {.inline.} =
  sharedJsonBuf.setLen(0)
  serializeDirectInto(sharedJsonBuf, obj)
  sharedJsonBuf

## Serialize ``obj`` to a fresh JSON string using the direct engine.
proc toJson*[T](obj: T): string {.inline.} =
  serializeDirect(obj)

## Deserialize JSON text ``json`` into a value of type T.
proc fromJson*[T](json: string): T {.inline.} =
  deserializeDirect(json, T)

## Deserialize JSON text ``json`` into the type given by the typedesc parameter.
proc fromJson*[T](json: string, _: typedesc[T]): T {.inline.} =
  deserializeDirect(json, T)

## Serialize ``obj`` to a fresh JSON string.
proc serialize*[T](obj: T): string {.inline.} =
  serializeDirect(obj)

## Deserialize JSON text ``json`` into the type given by the typedesc parameter.
proc deserialize*[T](json: string, _: typedesc[T]): T {.inline.} =
  deserializeDirect(json, T)

## Deserialize ``json`` into T, returning ``default`` when parsing fails.
proc fromJsonOr*[T](json: string, default: T): T =
  try:
    deserializeDirect(json, T)
  except CatchableError:
    default

## Deserialize ``json`` into an Option, yielding none when parsing fails.
proc tryFromJson*[T](json: string): Option[T] =
  try:
    some(deserializeDirect(json, T))
  except CatchableError:
    none(T)

type
  JsonError* = object
    error*: string

  JsonMessage* = object
    message*: string

  JsonStatus* = object
    status* {.jsonSafe.}: string

  JsonData*[T] = object
    data*: T

  JsonSuccess*[T] = object
    success*: bool
    data*: T

  JsonList*[T] = object
    items*: seq[T]
    count*: int

## Build a JSON error body containing ``msg``.
proc errorJson*(msg: string): string {.inline.} =
  serializeDirect(JsonError(error: msg))

## Build a JSON message body containing ``msg``.
proc messageJson*(msg: string): string {.inline.} =
  serializeDirect(JsonMessage(message: msg))

## Build a JSON status body containing ``status``.
proc statusJson*(status: string): string {.inline.} =
  serializeDirect(JsonStatus(status: status))

## Build a JSON data envelope containing ``data``.
proc dataJson*[T](data: T): string {.inline.} =
  serializeDirect(JsonData[T](data: data))

## Build a JSON success envelope containing ``data``.
proc successJson*[T](data: T): string {.inline.} =
  serializeDirect(JsonSuccess[T](success: true, data: data))

## Build a JSON list envelope with items and count for ``items``.
proc listJson*[T](items: seq[T]): string {.inline.} =
  serializeDirect(JsonList[T](items: items, count: items.len))
