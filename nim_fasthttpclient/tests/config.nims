import std/[os, strutils]

# Resolve uSockets.a relative to this config file's directory so it works
# regardless of CWD.
const cfgDir = currentSourcePath().parentDir
const uSocketsLib = cfgDir / ".." / ".." / "nim_usockets" / "usockets" / "uSockets.a"

switch("passL", uSocketsLib)

when defined(macosx):
  switch("define", "LIBUS_USE_GCD")
  switch("passL", "-framework CoreFoundation")
elif defined(linux):
  switch("passC", "-D_GNU_SOURCE")
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
