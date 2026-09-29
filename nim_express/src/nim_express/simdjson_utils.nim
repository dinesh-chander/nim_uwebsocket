import std/[strutils]

import nim_utils/nim_fastjson/simdjson

type
  FastTodoMutationPayload* = object
    hasTitle*: bool
    title*: string
    hasCompleted*: bool
    completed*: bool

## Returns true if ``body`` is syntactically valid JSON.
proc validateJsonFast*(body: string): bool {.inline.} =
  isValidJson(body)

## Parses ``raw`` as boolean text such as "true", "1", "yes", or "on".
proc parseBoolTextFast*(raw: string): tuple[ok: bool, value: bool] =
  case raw.toLowerAscii()
  of "1", "true", "yes", "on":
    (true, true)
  of "0", "false", "no", "off":
    (true, false)
  else:
    (false, false)

## Parses a todo mutation JSON body with optional ``title`` and ``completed`` fields.
proc parseTodoMutationPayloadFast*(body: string): tuple[ok: bool, payload: FastTodoMutationPayload, error: string] =
  try:
    let doc = parse(body)
    let root = doc.root()
    if root.kind != jkObject:
      return (false, FastTodoMutationPayload(), "expected JSON object body")
    let cursor = root.objectCursor()

    var valueKind: JsonKind

    if cursor.tryKeyKind("title", valueKind):
      if valueKind != jkString:
        return (false, FastTodoMutationPayload(), "title must be a string")
      result.payload.hasTitle = true
      var title: string
      if not cursor.tryGetStr("title", title):
        return (false, FastTodoMutationPayload(), "title must be a string")
      result.payload.title = title.strip()

    if cursor.tryKeyKind("completed", valueKind):
      result.payload.hasCompleted = true
      case valueKind
      of jkBool:
        if not cursor.tryGetBool("completed", result.payload.completed):
          return (false, FastTodoMutationPayload(), "completed must be bool-like")
      of jkInt64:
        var value: int64
        if not cursor.tryGetInt64("completed", value):
          return (false, FastTodoMutationPayload(), "completed must be bool-like")
        result.payload.completed = value != 0
      of jkUint64:
        var value: uint64
        if not cursor.tryGetUint64("completed", value):
          return (false, FastTodoMutationPayload(), "completed must be bool-like")
        result.payload.completed = value != 0'u64
      of jkString:
        var raw: string
        if not cursor.tryGetStr("completed", raw):
          return (false, FastTodoMutationPayload(), "completed must be bool-like")
        let parsed = parseBoolTextFast(raw)
        if not parsed.ok:
          return (false, FastTodoMutationPayload(), "completed must be bool-like")
        result.payload.completed = parsed.value
      else:
        return (false, FastTodoMutationPayload(), "completed must be bool-like")

    result.ok = true
  except SimdjsonError:
    result.error = "expected JSON object body"
