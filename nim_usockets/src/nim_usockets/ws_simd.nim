import std/os

{.passc: "-I" & parentDir(currentSourcePath()).}

proc ws_unmask(payload: ptr char; len: csize_t; maskKey: ptr char) {.importc: "ws_unmask", header: "ws_unmask_simd.h".}

## Unmasks a WebSocket payload in place with the given four-byte key using the SIMD-accelerated C helper.
proc wsUnmaskPayload*(payload: ptr char, len: int, maskKey: array[4, char]) {.inline.} =
  ws_unmask(payload, cast[csize_t](len), cast[ptr char](unsafeAddr maskKey[0]))
