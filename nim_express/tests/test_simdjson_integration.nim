import std/unittest

import ../src/nim_express/simdjson_utils

suite "simdjson integration":
  test "todo payload parser accepts title and bool-like completed":
    let parsed = parseTodoMutationPayloadFast("""{"title":"  ship wrapper  ","completed":"yes"}""")

    check parsed.ok
    check parsed.payload.hasTitle
    check parsed.payload.title == "ship wrapper"
    check parsed.payload.hasCompleted
    check parsed.payload.completed

  test "todo payload parser accepts integer completed":
    let parsed = parseTodoMutationPayloadFast("""{"completed":0}""")

    check parsed.ok
    check parsed.payload.hasCompleted
    check not parsed.payload.completed

  test "todo payload parser rejects invalid shape":
    let missingTitle = parseTodoMutationPayloadFast("""["nope"]""")
    check not missingTitle.ok
    check missingTitle.error == "expected JSON object body"

    let badCompleted = parseTodoMutationPayloadFast("""{"completed":{"nested":true}}""")
    check not badCompleted.ok
    check badCompleted.error == "completed must be bool-like"
