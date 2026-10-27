import os

version = "0.1.0"
author = "nim_uwebsocket contributors"
description = "High-performance web framework for Nim with HTTP/1.1, HTTP/2, WebSocket, and SSE support"
license = "MIT"
licenseFile = "LICENSE"
srcDir = "."
skipDirs = @["benchmark", "docs", "doc", "analysis", "optimization_plan", ".claude", "tmp", "tmp_bench"]

requires "nim >= 2.2.10"
requires "nim_utils == 0.1.0"
requires "nim_usockets == 0.1.0"
requires "nim_fasthttpclient == 0.1.0"
requires "nim_express == 0.1.0"
requires "zippy == 0.10.19"
requires "brotli == 0.2.0"
requires "zstd == 0.9.0"
requires "libdeflate_gzip == 0.6.0"
requires "malebolgia == 1.3.2"
requires "jsony == 1.1.6"
requires "checksums == 0.2.2"
requires "nimsimd == 1.3.2"

let rootDir = thisDir()
let nimUtilsSrc = rootDir / "nim_utils" / "src"
let nimUsocketsSrc = rootDir / "nim_usockets" / "src"
let nimExpressSrc = rootDir / "nim_express" / "src"
let nimFastHttpClientSrc = rootDir / "nim_fasthttpclient" / "src"
let usocketsArchive = rootDir / "nim_usockets" / "usockets" / "uSockets.a"
let buildFlags = "-d:release --opt:speed --hints:off"

proc wantsIoUring(): bool =
  result = getEnv("USOCKETS_BACKEND", "") == "io_uring"
  when defined(useIoUring) or defined(LIBUS_USE_IO_URING):
    result = true

proc platformLinkFlags(): string =
  when defined(macosx):
    result = "-framework CoreFoundation"
  elif defined(linux):
    result = "-lpthread -ldl"
    if wantsIoUring():
      result.add " -luring"
  else:
    result = ""

task build_usockets, "Build bundled uSockets library":
  var backend = getEnv("USOCKETS_BACKEND", "")
  when defined(macosx):
    if backend.len == 0:
      backend = "gcd"
  else:
    if backend.len == 0:
      backend = if wantsIoUring(): "io_uring" else: "epoll"
  exec "make -C " & quoteShell(rootDir) & " usockets USOCKETS_BACKEND=" & quoteShell(backend)

task build_nim_utils, "Compile nim_utils":
  exec "nim c " & buildFlags & " " & quoteShell(nimUtilsSrc / "nim_utils.nim")

task build_nim_fastjson, "Compile nim_fastjson":
  exec "nim c " & buildFlags & " --path:" & quoteShell(nimUtilsSrc) & " " &
    quoteShell(nimUtilsSrc / "nim_utils" / "nim_fastjson.nim")

task build_nim_usockets, "Compile nim_usockets":
  exec "cd " & quoteShell(rootDir / "nim_usockets") &
    " && nim c " & buildFlags & " --path:" & quoteShell("../nim_utils/src") & " src/nim_usockets.nim"

task build_nim_express, "Compile nim_express":
  exec "cd " & quoteShell(rootDir / "nim_express") &
    " && nim c " & buildFlags &
    " --path:" & quoteShell("../nim_utils/src") &
    " --path:" & quoteShell("../nim_usockets/src") &
    " --path:" & quoteShell("../nim_fasthttpclient/src") &
    " --passL:" & quoteShell("../nim_usockets/usockets/uSockets.a " & platformLinkFlags()) &
    " src/nim_express.nim"

task build_packages, "Build all Nim packages in the workspace":
  exec "nimble build_usockets -y"
  exec "nimble build_nim_utils -y"
  exec "nimble build_nim_fastjson -y"
  exec "nimble build_nim_usockets -y"
  exec "nimble build_nim_express -y"

task setup, "Build bundled dependencies and compile all packages":
  exec "nimble build_packages -y"

task test, "Run all test suites":
  let linkFlags = usocketsArchive & " " & platformLinkFlags()
  exec "echo '=== nim_express tests ==='"
  for f in listFiles("nim_express/tests"):
    if f.endsWith(".nim") and f.contains("test_"):
      exec "nim c -r --panics:off --hints:off --path:nim_express/src --path:nim_usockets/src --path:nim_utils/src --path:nim_fasthttpclient/src --path:vendor/nimsimd/src --passL:" & quoteShell(linkFlags) & " " & quoteShell(f)
  exec "echo '=== nim_usockets tests ==='"
  for f in listFiles("nim_usockets/tests"):
    if f.endsWith(".nim") and f.contains("test_"):
      exec "nim c -r --panics:off --hints:off --path:nim_usockets/src --path:nim_utils/src --path:vendor/nimsimd/src --passL:" & quoteShell(linkFlags) & " " & quoteShell(f)
  exec "echo '=== nim_fastjson tests ==='"
  for f in listFiles("nim_utils/nim_fastjson/tests"):
    if f.endsWith(".nim") and f.contains("test_"):
      exec "nim c -r --panics:off --hints:off --path:nim_utils/src " & quoteShell(f)
