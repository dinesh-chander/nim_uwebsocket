import std/[json, strutils]

import nim_utils/nim_fastjson/direct_engine

type
  FastTodoMutationPayload* = object
    hasTitle*: bool
    title*: string
    hasCompleted*: bool
    completed*: bool

## Returns true if ``body`` is syntactically valid JSON.
proc validateJsonFast*(body: string): bool {.inline.} =
  isValidJsonDirect(body)

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
    let root = parseJson(body)
    if root.kind != JObject:
      return (false, FastTodoMutationPayload(), "expected JSON object body")

    if root.hasKey("title"):
      let titleNode = root["title"]
      if titleNode.kind != JString:
        return (false, FastTodoMutationPayload(), "title must be a string")
      result.payload.hasTitle = true
      result.payload.title = titleNode.getStr.strip()

    if root.hasKey("completed"):
      result.payload.hasCompleted = true
      case root["completed"].kind
      of JBool:
        result.payload.completed = root["completed"].getBool
      of JInt:
        result.payload.completed = root["completed"].getInt != 0
      of JString:
        let parsed = parseBoolTextFast(root["completed"].getStr)
        if not parsed.ok:
          return (false, FastTodoMutationPayload(), "completed must be bool-like")
        result.payload.completed = parsed.value
      else:
        return (false, FastTodoMutationPayload(), "completed must be bool-like")

    result.ok = true
  except CatchableError:
    result.error = "expected JSON object body"
