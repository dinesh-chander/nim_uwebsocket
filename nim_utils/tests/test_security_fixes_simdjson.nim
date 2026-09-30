import std/[os, unittest, strutils]

import ../src/nim_utils/nim_fastjson/simdjson/simdjson_ffi

proc jsonCPtr(s: string): cstring =
  ## View a Nim string as a NUL-terminated C string (payloads are non-empty and
  ## contain no NUL bytes); the decoder is given the exact length as well.
  cast[cstring](unsafeAddr s[0])

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

# Payloads are sized >= 128KB so the decoder pre-allocates its maximum
# todos buffer (4096 items) before hitting the error path.
var pad = newStringOfCap(130_000)
for i in 0 ..< 130_000:
  pad.add 'a'

const
  rootMissingTodos = """{"meta":{"page":1,"count":0},"pad":"PAD"}"""
  rootBadTodosType = """{"meta":{"page":1,"count":0},"todos":"not-an-array","pad":"PAD"}"""

let missingTodosJson = rootMissingTodos.replace("PAD", pad)
let badTodosJson = rootBadTodosType.replace("PAD", pad)

suite "simdjson shim security fixes":
  test "F1: missing todos takes error path and releases temp buffer":
    var envelope: CMediumTodoEnvelope
    let err = simdjsonExtractMediumTodoEnvelope(
      missingTodosJson.jsonCPtr(), missingTodosJson.len.csize_t, addr envelope)
    check err != 0'u32
    check envelope.todos == nil
    simdjsonMediumTodoEnvelopeRelease(addr envelope)

  test "F1: mistyped todos takes error path and releases temp buffer":
    var envelope: CMediumTodoEnvelope
    let err = simdjsonExtractMediumTodoEnvelope(
      badTodosJson.jsonCPtr(), badTodosJson.len.csize_t, addr envelope)
    check err != 0'u32
    check envelope.todos == nil
    simdjsonMediumTodoEnvelopeRelease(addr envelope)

  test "F1: malformed todos path does not leak RSS across repeated calls":
    # Warm up allocator/parser state so the baseline is stable.
    for i in 0 ..< 20:
      var envelope: CMediumTodoEnvelope
      discard simdjsonExtractMediumTodoEnvelope(
        missingTodosJson.jsonCPtr(), missingTodosJson.len.csize_t, addr envelope)
      simdjsonMediumTodoEnvelopeRelease(addr envelope)

    let rssBefore = readVmRssKb()
    for i in 0 ..< 200:
      var envelope: CMediumTodoEnvelope
      discard simdjsonExtractMediumTodoEnvelope(
        missingTodosJson.jsonCPtr(), missingTodosJson.len.csize_t, addr envelope)
      simdjsonMediumTodoEnvelopeRelease(addr envelope)
    let rssAfter = readVmRssKb()
    # On Linux /proc is available; on other platforms skip the bound check.
    if rssBefore > 0 and rssAfter > 0:
      # A leak would grow ~128KB x 200 = 25MB; bound keeps margin for
      # allocator retention while still catching the leak.
      check rssAfter - rssBefore < 8192
