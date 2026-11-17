# Manual builds from this directory (`nim c websocketload.nim`). The top-level
# Makefile builds this binary with --skipProjCfg and probes the compiler for the
# native flags, so it does not read this file.

when defined(nativeOpt):
  # `-march=native -mtune=native` is the x86 spelling. clang on Apple Silicon
  # rejects it ("unsupported argument 'native' to option '-march='") and wants
  # -mcpu=native, which is tuning-only on x86 and so must not replace it there.
  when defined(arm64) or defined(arm):
    switch("passC", "-mcpu=native")
  else:
    switch("passC", "-march=native -mtune=native")
