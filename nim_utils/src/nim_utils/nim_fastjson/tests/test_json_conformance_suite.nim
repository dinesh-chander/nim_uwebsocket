## JSON syntax conformance harness for nim_fastjson's direct parser.
## Uses the external JSONTestSuite corpus when available.
##
## Expected layout:
##   $JSON_TEST_SUITE_DIR/test_parsing/*.json
## or directly:
##   $JSON_TEST_SUITE_DIR/*.json

import std/[os, unittest]

import ../direct_engine

proc hasJsonFiles(path: string): bool =
  for _ in walkFiles(path / "*.json"):
    return true
  false

const MissingSuiteMessage =
  "ERROR test_json_conformance_suite: JSONTestSuite corpus is missing or empty. " &
  "Restore tests/vendor/JSONTestSuite or set JSON_TEST_SUITE_DIR to a JSONTestSuite checkout."

proc resolveSuiteDir(): string =
  let configured = getEnv("JSON_TEST_SUITE_DIR")
  if configured.len == 0:
    let bundled = currentSourcePath.parentDir / "vendor" / "JSONTestSuite"
    if dirExists(bundled / "test_parsing") and hasJsonFiles(bundled / "test_parsing"):
      return bundled / "test_parsing"
    if dirExists(bundled) and hasJsonFiles(bundled):
      return bundled
    return ""

  if dirExists(configured / "test_parsing") and hasJsonFiles(configured / "test_parsing"):
    return configured / "test_parsing"
  if dirExists(configured) and hasJsonFiles(configured):
    return configured
  ""

proc acceptsJson(payload: string): bool =
  isValidJsonDirect(payload)

let suiteDir = resolveSuiteDir()

if suiteDir.len == 0:
  stderr.writeLine(MissingSuiteMessage)
  quit(QuitFailure)

suite "JSONTestSuite syntax conformance":
  test "y_ and n_ cases match expected parser result":
    var yCount = 0
    var nCount = 0
    var iCount = 0

    for path in walkFiles(suiteDir / "*.json"):
      let name = path.extractFilename()
      if name.len < 2 or name[1] != '_':
        continue

      let payload = readFile(path)
      let accepted = acceptsJson(payload)
      let valid = isValidJsonDirect(payload)

      checkpoint("case=" & name)
      check accepted == valid

      case name[0]
      of 'y':
        inc yCount
        check accepted
      of 'n':
        inc nCount
        check not accepted
      of 'i':
        inc iCount
      else:
        discard

    checkpoint("suiteDir=" & suiteDir &
      " y=" & $yCount &
      " n=" & $nCount &
      " i=" & $iCount)
    check yCount > 0
    check nCount > 0
