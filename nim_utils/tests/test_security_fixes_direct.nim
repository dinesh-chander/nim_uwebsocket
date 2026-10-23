import std/[os, unittest, strutils]

import ../src/nim_utils/nim_fastjson

type
  Meta = object
    page*: int
    count*: int

  Todo = object
    id*: int
    title*: string

  TodoEnvelope = object
    meta*: Meta
    todos*: seq[Todo]
    pad*: string

proc readVmRssKb(): int =
  ## Read current process resident set size in KiB (Linux /proc).
  let statusPath = "/proc/self/status"
  if not fileExists(statusPath):
    return -1
  for line in lines(statusPath):
    if line.startsWith("VmRSS:"):
      let rest = line["VmRSS: ".len .. line.high].strip()
      let sp = rest.find(' ')
      if sp >= 0:
        try:
          return parseInt(rest[0 .. sp - 1])
        except ValueError:
          return -1
  return -1

# Payload is sized >= 128KB so the decoder allocates its full output buffers
# before hitting the error path.
var pad = newStringOfCap(130_000)
for i in 0 ..< 130_000:
  pad.add 'a'

const
  rootMissingTodos = """{"meta":{"page":1,"count":0},"pad":"PAD"}"""
  rootBadTodosType = """{"meta":{"page":1,"count":0},"todos":"not-an-array","pad":"PAD"}"""

let missingTodosJson = rootMissingTodos.replace("PAD", pad)
let badTodosJson = rootBadTodosType.replace("PAD", pad)
let fj = initFastJson()

suite "direct engine security fixes":
  test "F1: missing todos decodes with defaults and no crash":
    let parsed = fj.deserialize(missingTodosJson, TodoEnvelope)
    check parsed.todos.len == 0
    check parsed.meta.page == 1

  test "F1: mistyped todos takes error path":
    var raised = false
    try:
      discard fj.deserialize(badTodosJson, TodoEnvelope)
    except JsonError:
      raised = true
    check raised

  test "F1: malformed todos path does not leak RSS across repeated calls":
    # Warm up allocator/parser state so the baseline is stable.
    for i in 0 ..< 20:
      try:
        discard fj.deserialize(badTodosJson, TodoEnvelope)
      except JsonError:
        discard

    let rssBefore = readVmRssKb()
    for i in 0 ..< 200:
      try:
        discard fj.deserialize(badTodosJson, TodoEnvelope)
      except JsonError:
        discard
    let rssAfter = readVmRssKb()
    # On Linux /proc is available; on other platforms skip the bound check.
    if rssBefore > 0 and rssAfter > 0:
      # A leak would grow ~128KB x 200 = 25MB; bound keeps margin for
      # allocator retention while still catching the leak.
      check rssAfter - rssBefore < 8192
