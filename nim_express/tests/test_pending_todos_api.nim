import std/[unittest, os, strutils, times]

import ../src/nim_express/[app, request, response, types, paged_buffer]

proc toFastMap(entries: openArray[(string, string)]): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(max(8, entries.len * 2))
  for (k, v) in entries:
    discard result.put(k, v)

suite "Pending todo APIs":
  test "typed request coercion helpers parse and validate":
    var nativeReq: HttpRequest
    new(nativeReq)
    nativeReq.methodKind = hmGet

    let req = newRequest(nativeReq)
    discard req.params.put("limit", "20")
    discard req.params.put("enabled", "yes")

    let parsedLimit = req.paramInt("limit", minValue = 1, maxValue = 100)
    check parsedLimit.ok
    check parsedLimit.value == 20

    let parsedEnabled = req.paramBool("enabled")
    check parsedEnabled.ok
    check parsedEnabled.value

    let optionalPage = req.queryInt("page", required = false, defaultValue = 7)
    check optionalPage.ok
    check optionalPage.value == 7

    discard req.params.put("limit", "abc")
    let invalidLimit = req.paramInt("limit")
    check not invalidLimit.ok
    check invalidLimit.error.field == "limit"
    check invalidLimit.error.reason == "invalid integer"

  test "coercion error maps to deterministic 400 response":
    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet
    nativeRes.connectionClose = false

    let res = newResponse(nativeRes)
    let err = RequestCoercionError(
      source: rfsQuery,
      field: "limit",
      rawValue: "abc",
      reason: "invalid integer"
    )
    res.badRequest(err)
    check res.statusCode == 400
    check nativeRes.bodyWasSent() == true

  test "compiled template and render plan helpers":
    let compiled = compileTemplate("<h1>{{ title }}</h1>")
    let locals = toFastMap([("title", "<Admin>")])
    check renderTemplate(compiled, locals) == "<h1>&lt;Admin&gt;</h1>"

    let plan = compileRenderPlan("<li>{{name}}</li>")
    var buf = initPageBuffer(32)
    buf.appendRenderPlan(plan, toFastMap([("name", "<b>A</b>")]))
    check buf.takeStringAndClear() == "<li>&lt;b&gt;A&lt;/b&gt;</li>"
    buf.release()

  test "row stream adapter renders repeated rows":
    let plan = compileRenderPlan("<li>{{name}}</li>")
    var buf = initPageBuffer(64)
    let streamed = streamRenderPlanRows(
      buf,
      plan,
      proc(emitRow: RowEmitProc): int =
        var emitted = 0
        for entry in ["Alpha", "Beta"]:
          let current = entry
          if not emitRow(proc(key: string, value: var string): bool =
            if key == "name":
              value = current
              return true
            false
          ):
            break
          inc emitted
        emitted
    )
    check streamed == 2
    check buf.takeStringAndClear() == "<li>Alpha</li><li>Beta</li>"
    buf.release()

  test "adaptive page buffer send policy supports contiguous mode":
    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet
    nativeRes.connectionClose = false

    let res = newResponse(nativeRes)
    var buf = initPageBuffer(64)
    buf.add("hello")
    var policy = defaultPageBufferSendPolicy()
    policy.mode = pbsmContiguous
    check res.sendPageBuffer(buf, "text/plain; charset=utf-8", policy)
    check buf.buffered == 0
    check nativeRes.bodyWasSent() == true
    buf.release()

  test "page buffer zero-copy header prefix does not reuse stale custom headers":
    var nativeA: HttpResponse
    new(nativeA)
    nativeA.requestMethod = hmGet
    nativeA.connectionClose = false
    let resA = newResponse(nativeA)
    resA.set("X-A", "1")
    var bufA = initPageBuffer(32)
    bufA.add("alpha")
    check resA.sendPageBuffer(bufA, "text/plain; charset=utf-8")
    check nativeA.capturedRaw.contains("x-a: 1")

    var nativeB: HttpResponse
    new(nativeB)
    nativeB.requestMethod = hmGet
    nativeB.connectionClose = false
    let resB = newResponse(nativeB)
    resB.set("X-B", "2")
    var bufB = initPageBuffer(32)
    bufB.add("beta")
    check resB.sendPageBuffer(bufB, "text/plain; charset=utf-8")
    check nativeB.capturedRaw.contains("x-b: 2")
    check not nativeB.capturedRaw.contains("x-a: 1")

  test "startup warmup hooks execute once and can queue precompile hooks":
    let webApp = newExpressApp()
    var runs = 0
    webApp.onStartupWarmup(proc(ctx: ExpressApp) =
      inc runs
    )

    webApp.runStartupWarmups()
    webApp.runStartupWarmups()
    check runs == 1

    let tmpRoot = getTempDir() / ("nim_express_startup_" & $epochTime())
    createDir(tmpRoot)
    try:
      writeFile(tmpRoot / "index.html", "<div>{{name}}</div>")
      webApp.setViewsDir(tmpRoot)
      let queued = webApp.precompileViewsOnStartup(["index"])
      check queued == 1

      # Newly registered hooks run once without replaying previous hooks.
      webApp.runStartupWarmups()
      check runs == 1
    finally:
      if dirExists(tmpRoot):
        removeDir(tmpRoot)

  test "template/view caches expose hit miss and eviction counters":
    clearTemplateCaches()
    resetTemplateViewCacheStats()
    setTemplateViewCachePolicy(
      templateMaxEntries = 8,
      templateMaxBytes = 1024 * 1024,
      viewMaxEntries = 8,
      viewMaxBytes = 1024 * 1024
    )

    let tmpRoot = getTempDir() / ("nim_express_view_cache_" & $epochTime())
    createDir(tmpRoot)
    defer:
      if dirExists(tmpRoot):
        removeDir(tmpRoot)

    writeFile(tmpRoot / "index.html", "<h1>{{title}}</h1>")

    let app = newExpressApp()
    app.setViewsDir(tmpRoot)
    app.setViewExtension(".html")

    var nativeRes1: HttpResponse
    new(nativeRes1)
    nativeRes1.requestMethod = hmGet
    let res1 = newResponse(nativeRes1)
    res1.app = app
    res1.viewsDir = tmpRoot
    res1.viewExt = ".html"
    let loaded1 = res1.loadView("index")
    check loaded1.ok

    var nativeRes2: HttpResponse
    new(nativeRes2)
    nativeRes2.requestMethod = hmGet
    let res2 = newResponse(nativeRes2)
    res2.app = app
    res2.viewsDir = tmpRoot
    res2.viewExt = ".html"
    let loaded2 = res2.loadView("index")
    check loaded2.ok

    check precompileViewTemplate(tmpRoot, ".html", "index")
    check precompileViewTemplate(tmpRoot, ".html", "index")

    let stats = templateViewCacheStats()
    check stats.get("view_misses", 0'i64) >= 1
    check stats.get("view_hits", 0'i64) >= 1
    check stats.get("template_misses", 0'i64) >= 1
    check stats.get("template_hits", 0'i64) >= 1

  test "template/view caches enforce deterministic bounded eviction":
    clearTemplateCaches()
    resetTemplateViewCacheStats()
    setTemplateViewCachePolicy(
      templateMaxEntries = 1,
      templateMaxBytes = 256,
      viewMaxEntries = 1,
      viewMaxBytes = 256
    )

    let tmpRoot = getTempDir() / ("nim_express_view_evict_" & $epochTime())
    createDir(tmpRoot)
    defer:
      if dirExists(tmpRoot):
        removeDir(tmpRoot)

    writeFile(tmpRoot / "a.html", "<div>{{name}}</div>")
    writeFile(tmpRoot / "b.html", "<div>{{name}}</div>")

    check precompileViewTemplate(tmpRoot, ".html", "a")
    check precompileViewTemplate(tmpRoot, ".html", "b")

    let stats = templateViewCacheStats()
    check stats.get("template_evictions", 0'i64) >= 1
    check stats.get("view_evictions", 0'i64) >= 1
