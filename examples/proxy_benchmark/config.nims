import std/os

let rootDir = currentSourcePath().parentDir().parentDir().parentDir()

for path in [
  "nim_utils/src",
  "nim_usockets/src",
  "nim_fasthttpclient/src",
  "nim_express/src",
  "vendor/zippy/src",
  "vendor/brotli/src",
  "vendor/nim_zstd",
  "vendor/nim_libdeflate_gzip/src",
  "vendor/malebolgia/src",
  "vendor/jsony/src",
  "vendor/checksums"
]:
  switch("path", rootDir / path)

switch("passL", rootDir / "nim_usockets/usockets/uSockets.a")

when defined(macosx):
  switch("passL", "-framework CoreFoundation")
elif defined(linux):
  switch("passC", "-D_GNU_SOURCE -ftls-model=local-exec")
  switch("passL", "-lpthread")
  switch("passL", "-ldl")
  let envUsesIoUring = getEnv("USOCKETS_BACKEND") == "io_uring"
  when defined(LIBUS_USE_IO_URING) or defined(useIoUring):
    switch("passC", "-DLIBUS_USE_IO_URING")
    switch("passL", "-luring")
  else:
    if envUsesIoUring:
      switch("passC", "-DLIBUS_USE_IO_URING")
      switch("passL", "-luring")
