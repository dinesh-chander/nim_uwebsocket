## Shared helpers for runnable examples.

import std/[os, strutils]

proc firstExistingDir(candidates: openArray[string]): string =
  for candidate in candidates:
    if candidate.len == 0:
      continue
    let resolved = absolutePath(candidate)
    if dirExists(resolved):
      return resolved
  ""

proc parsePort*(defaultPort: int = 3000): int =
  try:
    result = parseInt(getEnv("PORT", $defaultPort))
  except ValueError:
    result = defaultPort

proc resolveViewsDir*(subdir: string): string =
  let appDir = getAppDir()
  firstExistingDir([
    joinPath(appDir, "../views", subdir),
    joinPath(appDir, "../../examples/views", subdir),
    joinPath(appDir, "../examples/views", subdir),
    joinPath("examples/views", subdir),
    joinPath("views", subdir)
  ])

proc resolvePublicDir*(subdir: string = ""): string =
  let appDir = getAppDir()
  firstExistingDir([
    joinPath(appDir, "../public", subdir),
    joinPath(appDir, "../../examples/public", subdir),
    joinPath(appDir, "../examples/public", subdir),
    joinPath("examples/public", subdir),
    joinPath("public", subdir)
  ])

proc resolveGeneratedDir*(subdir: string): string =
  let root = firstExistingDir([
    joinPath(getAppDir(), "../generated"),
    joinPath(getAppDir(), "../../examples/generated"),
    "examples/generated",
    "generated"
  ])

  let base =
    if root.len > 0:
      root
    else:
      let fallback = absolutePath("examples/generated")
      try:
        createDir(fallback)
      except CatchableError:
        discard
      fallback

  let resolved = joinPath(base, subdir)
  try:
    if not dirExists(resolved):
      createDir(resolved)
  except CatchableError:
    discard
  resolved
