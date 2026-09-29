## Scaffold helpers for bulk middleware/route registration.

import types
import app

type
  ScaffoldRouteKind* = enum
    srkSync
    srkAsync

  ScaffoldRoute* = object
    methodKind*: nim_usockets.HttpMethod
    pattern*: string
    case kind*: ScaffoldRouteKind
    of srkSync:
      syncHandler*: SyncHandler
    of srkAsync:
      asyncHandler*: AsyncHandler

## Builds a `ScaffoldRoute` for a synchronous handler with the given method and pattern.
proc syncRoute*(
  methodKind: nim_usockets.HttpMethod,
  pattern: string,
  handler: SyncHandler
): ScaffoldRoute =
  ScaffoldRoute(
    kind: srkSync,
    methodKind: methodKind,
    pattern: pattern,
    syncHandler: handler
  )

## Builds a `ScaffoldRoute` for an asynchronous handler with the given method and pattern.
proc asyncRoute*(
  methodKind: nim_usockets.HttpMethod,
  pattern: string,
  handler: AsyncHandler
): ScaffoldRoute =
  ScaffoldRoute(
    kind: srkAsync,
    methodKind: methodKind,
    pattern: pattern,
    asyncHandler: handler
  )

proc registerSync(app: ExpressApp, methodKind: nim_usockets.HttpMethod, pattern: string, handler: SyncHandler) =
  case methodKind
  of hmGet: app.get(pattern, handler)
  of hmPost: app.post(pattern, handler)
  of hmPut: app.put(pattern, handler)
  of hmDelete: app.delete(pattern, handler)
  of hmPatch: app.patch(pattern, handler)
  of hmHead: app.head(pattern, handler)
  of hmOptions: app.options(pattern, handler)
  else: app.all(pattern, handler)

proc registerAsync(app: ExpressApp, methodKind: nim_usockets.HttpMethod, pattern: string, handler: AsyncHandler) =
  case methodKind
  of hmGet: app.getAsync(pattern, handler)
  of hmPost: app.postAsync(pattern, handler)
  of hmPut: app.putAsync(pattern, handler)
  of hmDelete: app.deleteAsync(pattern, handler)
  of hmPatch: app.patchAsync(pattern, handler)
  of hmHead: app.headAsync(pattern, handler)
  of hmOptions: app.optionsAsync(pattern, handler)
  else: app.allAsync(pattern, handler)

proc registerSync(group: RouteGroup, methodKind: nim_usockets.HttpMethod, pattern: string, handler: SyncHandler) =
  case methodKind
  of hmGet: group.get(pattern, handler)
  of hmPost: group.post(pattern, handler)
  of hmPut: group.put(pattern, handler)
  of hmDelete: group.delete(pattern, handler)
  of hmPatch: group.patch(pattern, handler)
  of hmHead: group.head(pattern, handler)
  of hmOptions: group.options(pattern, handler)
  else: group.all(pattern, handler)

proc registerAsync(group: RouteGroup, methodKind: nim_usockets.HttpMethod, pattern: string, handler: AsyncHandler) =
  case methodKind
  of hmGet: group.getAsync(pattern, handler)
  of hmPost: group.postAsync(pattern, handler)
  of hmPut: group.putAsync(pattern, handler)
  of hmDelete: group.deleteAsync(pattern, handler)
  of hmPatch: group.patchAsync(pattern, handler)
  of hmHead: group.headAsync(pattern, handler)
  of hmOptions: group.optionsAsync(pattern, handler)
  else: group.allAsync(pattern, handler)

## Applies each non-nil async middleware to the app, returning early if the app is nil.
proc scaffoldMiddlewares*(app: ExpressApp, middlewares: openArray[AsyncMiddleware]) =
  if app == nil:
    return
  for middleware in middlewares:
    if middleware == nil:
      continue
    app.use(middleware)

## Applies each non-nil async middleware to the group, returning early if the group or its app is nil.
proc scaffoldMiddlewares*(group: RouteGroup, middlewares: openArray[AsyncMiddleware]) =
  if group == nil or group.app == nil:
    return
  for middleware in middlewares:
    if middleware == nil:
      continue
    group.use(middleware)

## Registers each scaffold route with a non-empty pattern on the app for its method, skipping nil handlers.
proc scaffoldRoutes*(app: ExpressApp, routes: openArray[ScaffoldRoute]) =
  if app == nil:
    return
  for route in routes:
    if route.pattern.len == 0:
      continue
    case route.kind
    of srkSync:
      if route.syncHandler != nil:
        app.registerSync(route.methodKind, route.pattern, route.syncHandler)
    of srkAsync:
      if route.asyncHandler != nil:
        app.registerAsync(route.methodKind, route.pattern, route.asyncHandler)

## Registers each scaffold route with a non-empty pattern on the group for its method, skipping nil handlers.
proc scaffoldRoutes*(group: RouteGroup, routes: openArray[ScaffoldRoute]) =
  if group == nil or group.app == nil:
    return
  for route in routes:
    if route.pattern.len == 0:
      continue
    case route.kind
    of srkSync:
      if route.syncHandler != nil:
        group.registerSync(route.methodKind, route.pattern, route.syncHandler)
    of srkAsync:
      if route.asyncHandler != nil:
        group.registerAsync(route.methodKind, route.pattern, route.asyncHandler)
