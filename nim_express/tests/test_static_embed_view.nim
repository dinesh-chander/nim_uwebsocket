import std/[os, unittest]

# Runtime-safe stand-in for `getProjectPath` (which is a compile-time VM op and
# traps at runtime). The harness runs tests from the repo root, so the fixture
# lives under the working directory.
var projectRoot = getCurrentDir()
import ../src/nim_express/[app, types, request, response]

# The macro resolves relative paths against the project path (repo root via
# the root nim.cfg), so the fixture is addressed the same way here.
const fixtureRel = "nim_express/tests/fixtures/embed_probe.html"
const fixtureContent = "<template id=\"embed-probe\">embedded-payload-12345</template>\n"

proc makeRes(): Response =
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = hmGet
  nativeRes.requestIsHttp11 = true
  result = newResponse(nativeRes)

suite "Static embed view":
  test "staticEmbedView inlines file content at compile time":
    let webApp = newExpressApp()
    staticEmbedView(webApp, "embed-probe", fixtureRel)

    let res = makeRes()
    res.app = webApp
    let loaded = res.loadView("embed-probe")
    doAssert loaded.ok, "expected embedded view to load, error: " & loaded.error
    doAssert loaded.content == fixtureContent, "content: " & loaded.content

  test "embedded content is immune to later on-disk changes":
    let webApp = newExpressApp()
    staticEmbedView(webApp, "embed-probe-2", fixtureRel)

    # Simulate post-build drift: a temp copy is mutated, but the view was
    # baked in from the original file.
    # `getProjectPath` is a compile-time-only op, so resolve the fixture at
    # runtime against the working directory (harness runs from the repo root;
    # the project path is a prefix of it either way).
    let fixtureFile = if (projectRoot / fixtureRel).fileExists():
      projectRoot / fixtureRel
    else:
      fixtureRel
    let tmpFile = getCurrentDir() / "test_static_embed_view_drift.html"
    try:
      copyFile(fixtureFile, tmpFile)
      writeFile(tmpFile, "<template>changed-at-runtime</template>")
      let res = makeRes()
      res.app = webApp
      let loaded = res.loadView("embed-probe-2")
      doAssert loaded.ok
      doAssert loaded.content == fixtureContent
    finally:
      try: removeFile(tmpFile) except OSError: discard
