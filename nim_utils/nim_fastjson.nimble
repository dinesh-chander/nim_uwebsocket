version       = "0.1.0"
author        = "nim_uwebsocket contributors"
description   = "Fast generic JSON package with direct typed serde and backend seams"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.2.10"

task test, "Run nim_fastjson tests":
  exec "nim c --path:../vendor/jsony/src -r src/nim_utils/nim_fastjson/tests/test_fastjson_core.nim"
