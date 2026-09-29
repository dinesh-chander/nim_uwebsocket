import std/[algorithm, os, streams, strutils, unittest]

import ../../nim_fastjson

const MissingSuiteMessage =
  "ERROR test_json_standard_suite: JSONTestSuite corpus is missing or empty. " &
  "Restore tests/vendor/JSONTestSuite or set JSON_TEST_SUITE_DIR to a JSONTestSuite checkout."

proc hasJsonFiles(path: string): bool =
  for _ in walkFiles(path / "*.json"):
    return true
  false

proc resolveSuiteDir(): string =
  let configured = getEnv("JSON_TEST_SUITE_DIR")
  let root =
    if configured.len == 0:
      currentSourcePath.parentDir / "vendor" / "JSONTestSuite"
    else:
      configured

  if dirExists(root / "test_parsing") and hasJsonFiles(root / "test_parsing"):
    return root / "test_parsing"
  if dirExists(root) and hasJsonFiles(root):
    return root
  ""

let suiteDir = resolveSuiteDir()

if suiteDir.len == 0:
  stderr.writeLine(MissingSuiteMessage)
  quit(QuitFailure)

proc sortedSuiteFiles(): seq[string] =
  for path in walkFiles(suiteDir / "*.json"):
    result.add(path)
  result.sort()

let suiteFiles = sortedSuiteFiles()

suite "nim_fastjson JSONTestSuite":
  let fj = initFastJson()

  test "JSONTestSuite y_ cases are accepted":
    var failures: seq[string]
    var checked = 0
    for path in suiteFiles:
      let name = path.extractFilename()
      if not name.startsWith("y_"):
        continue
      inc checked
      let payload = readFile(path)
      if not fj.isValidJson(payload):
        failures.add(name)
    check checked > 0
    check failures.len == 0

  test "JSONTestSuite n_ cases are rejected":
    var failures: seq[string]
    var checked = 0
    for path in suiteFiles:
      let name = path.extractFilename()
      if not name.startsWith("n_"):
        continue
      inc checked
      let payload = readFile(path)
      if fj.isValidJson(payload):
        failures.add(name)
    check checked > 0
    check failures.len == 0

  test "validation bytes and stream overloads behave like string validation":
    let okPayload = readFile(suiteDir / "y_structure_lonely_true.json")
    let okBytes = cast[seq[byte]](okPayload)
    check fj.isValidJson(okPayload)
    check fj.isValidJson(okBytes)
    let okStream = newStringStream(okPayload)
    check fj.isValidJson(okStream)
    okStream.close()

    let badPayload = readFile(suiteDir / "n_structure_array_trailing_garbage.json")
    let badBytes = cast[seq[byte]](badPayload)
    check not fj.isValidJson(badPayload)
    check not fj.isValidJson(badBytes)
    let badStream = newStringStream(badPayload)
    check not fj.isValidJson(badStream)
    badStream.close()
