import std/unittest
import ../src/nim_express/app

suite "Route hotpath metadata":
  test "dynamic route metadata is precompiled":
    let app = newExpressApp()
    app.get("/users/:id", proc(req: Request, res: Response) = discard)
    check app.router.getRoutes.len == 1
    let r = app.router.getRoutes[0]
    check r.isDynamic
    check r.staticPrefix == "/users/"
    check r.firstLiteralSegment == "users"
    check r.minSegmentCount == 2'i16
    check r.maxSegmentCount == 2'i16

  test "wildcard route metadata keeps open max segment count":
    let app = newExpressApp()
    app.get("/assets/*", proc(req: Request, res: Response) = discard)
    let r = app.router.getRoutes[0]
    check r.isDynamic
    check r.staticPrefix == "/assets/"
    check r.firstLiteralSegment == "assets"
    check r.minSegmentCount == 1'i16
    check r.maxSegmentCount == -1'i16

  test "startup artifact compile builds exact index and dynamic prefix buckets":
    let app = newExpressApp()
    app.get("/:id", proc(req: Request, res: Response) = discard)
    app.get("/users/:userId", proc(req: Request, res: Response) = discard)
    app.get("/users/:userId/books/*", proc(req: Request, res: Response) = discard)
    app.get("/users/settings", proc(req: Request, res: Response) = discard)

    check app.router.artifactsCompiled == false
    app.router.compileRouterArtifacts()
    check app.router.artifactsCompiled
    check app.router.getExactRoutes.get("/users/settings", -1'i64) == 3'i64
    check app.router.firstDynamicGet == 0
    check app.router.getDynamicBuckets.fallbackOrder.len == 3
    check app.router.getDynamicBuckets.anyPrefix.len == 1
    let usersBucket = int(ord('u'))
    check app.router.getDynamicBuckets.byPrefix[usersBucket].len == 2

  test "dynamic route before exact static preempts exact fast path":
    let app = newExpressApp()
    app.get("/users/:id", proc(req: Request, res: Response) = discard)
    app.get("/users/settings", proc(req: Request, res: Response) = discard)

    var params = newFastMap[string]()
    discard params.reserve(4)
    let matched = app.router.findRouteForMethod(hmGet, "/users/settings", params)
    check matched != nil
    check matched.pattern == "/users/:id"
    check params.get("id", "") == "settings"

  test "exact static route before dynamic uses exact fast path":
    let app = newExpressApp()
    app.get("/users/settings", proc(req: Request, res: Response) = discard)
    app.get("/users/:id", proc(req: Request, res: Response) = discard)

    var params = newFastMap[string]()
    discard params.reserve(4)
    let matched = app.router.findRouteForMethod(hmGet, "/users/settings", params)
    check matched != nil
    check matched.pattern == "/users/settings"
    check params.len == 0

  test "HEAD keeps explicit-head precedence and GET fallback":
    let app = newExpressApp()
    app.get("/fallback/:id", proc(req: Request, res: Response) = discard)
    app.get("/health", proc(req: Request, res: Response) = discard)
    app.head("/health", proc(req: Request, res: Response) = discard)

    var params = newFastMap[string]()
    discard params.reserve(4)
    let explicitHead = app.router.findRouteForMethod(hmHead, "/health", params)
    check explicitHead != nil
    check explicitHead.pattern == "/health"
    check explicitHead.kind == rkSync

    let fallbackHead = app.router.findRouteForMethod(hmHead, "/fallback/42", params)
    check fallbackHead != nil
    check fallbackHead.pattern == "/fallback/:id"
    check params.get("id", "") == "42"

  test "leading dynamic route can match later literal segment":
    let app = newExpressApp()
    app.get("/:tenant/users", proc(req: Request, res: Response) = discard)

    var params = newFastMap[string]()
    discard params.reserve(4)
    let matched = app.router.findRouteForMethod(hmGet, "/acme/users", params)
    check matched != nil
    check matched.pattern == "/:tenant/users"
    check params.get("tenant", "") == "acme"
