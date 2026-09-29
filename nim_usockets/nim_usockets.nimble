import os

version       = "0.1.0"
author        = "nim_uwebsocket contributors"
description   = "Nim bindings for uWebSockets - high performance HTTP and WebSocket server"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.2.10"
requires "nim_utils == 0.1.0"
requires "zippy == 0.10.19"

proc wantsIoUring(): bool =
  result = getEnv("USOCKETS_BACKEND", "") == "io_uring"
  when defined(useIoUring) or defined(LIBUS_USE_IO_URING):
    result = true

proc usocketsBuildEnv(): string =
  when defined(macosx):
    result = "WITH_GCD=1"
  else:
    if wantsIoUring():
      result = "WITH_IO_URING=1"
    else:
      result = ""

task build_usockets, "Build uSockets library":
  exec "cd usockets && " & usocketsBuildEnv() & " make"

task setup, "Build bundled uSockets sources":
  exec "cd usockets && make clean && " & usocketsBuildEnv() & " make"
