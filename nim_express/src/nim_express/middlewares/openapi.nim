## OpenAPI / Swagger spec generation middleware.
## Auto-generates OpenAPI 3.0 spec from registered routes and serves Swagger UI.

import std/[asyncdispatch, strutils, json, tables]
import common

type
  OpenApiContact* = object
    name*: string
    url*: string
    email*: string

  OpenApiInfo* = object
    title*: string
    version*: string
    description*: string
    contact*: OpenApiContact

  RouteDoc* = object
    summary*: string
    description*: string
    tags*: seq[string]
    operationId*: string
    deprecated*: bool
    requestBodyContentType*: string
    requestBodyDescription*: string
    responseDescription*: string
    responseContentType*: string
    parameters*: seq[OpenApiParam]

  OpenApiParam* = object
    name*: string
    location*: string
    description*: string
    required*: bool
    schema*: string

  OpenApiOptions* = object
    info*: OpenApiInfo
    specPath*: string
    uiPath*: string
    servers*: seq[string]

  OpenApiRegistry* = ref object
    docs: Table[string, RouteDoc]
    routes: seq[tuple[httpMethod: string, pattern: string]]
    version: int

## Return OpenAPI options with default API info and doc paths.
proc defaultOpenApiOptions*(): OpenApiOptions {.inline.} =
  OpenApiOptions(
    info: OpenApiInfo(
      title: "API",
      version: "1.0.0",
      description: "",
      contact: OpenApiContact()
    ),
    specPath: "/api-docs/openapi.json",
    uiPath: "/api-docs",
    servers: @[]
  )

## Create a new `OpenApiRegistry` for collecting route docs.
proc newOpenApiRegistry*(): OpenApiRegistry =
  new(result)
  result.docs = initTable[string, RouteDoc]()
  result.routes = @[]
  result.version = 0

proc docKey(httpMethod: string, pattern: string): string {.inline.} =
  httpMethod.toUpperAscii() & " " & pattern

## Register or update a `RouteDoc` for a `httpMethod` and `pattern` pair.
proc document*(registry: OpenApiRegistry, httpMethod: string, pattern: string, doc: RouteDoc) =
  if registry == nil:
    return
  let normalized = httpMethod.toUpperAscii()
  let key = docKey(normalized, pattern)
  let isUpdate = registry.docs.hasKey(key)
  registry.docs[key] = doc
  if not isUpdate:
    registry.routes.add((httpMethod: normalized, pattern: pattern))
  inc registry.version

## Register a `RouteDoc` for a GET route.
proc documentGet*(registry: OpenApiRegistry, pattern: string, doc: RouteDoc) =
  registry.document("get", pattern, doc)

## Register a `RouteDoc` for a POST route.
proc documentPost*(registry: OpenApiRegistry, pattern: string, doc: RouteDoc) =
  registry.document("post", pattern, doc)

## Register a `RouteDoc` for a PUT route.
proc documentPut*(registry: OpenApiRegistry, pattern: string, doc: RouteDoc) =
  registry.document("put", pattern, doc)

## Register a `RouteDoc` for a DELETE route.
proc documentDelete*(registry: OpenApiRegistry, pattern: string, doc: RouteDoc) =
  registry.document("delete", pattern, doc)

## Register a `RouteDoc` for a PATCH route.
proc documentPatch*(registry: OpenApiRegistry, pattern: string, doc: RouteDoc) =
  registry.document("patch", pattern, doc)

proc isValidOpenApiParamName(name: string): bool {.inline.} =
  if name.len == 0:
    return false
  for c in name:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'}:
      return false
  true

proc convertPatternToOpenApi(pattern: string): string {.inline.} =
  result = newStringOfCap(pattern.len + 4)
  var i = 0
  while i < pattern.len:
    if pattern[i] == ':':
      inc i
      let nameStart = i
      while i < pattern.len and pattern[i] != '/':
        inc i
      if i > nameStart:
        let name = pattern[nameStart ..< i]
        if isValidOpenApiParamName(name):
          result.add('{')
          result.add(name)
          result.add('}')
        else:
          result.add(name)
      else:
        result.add(':')
    else:
      result.add(pattern[i])
      inc i

proc extractPathParams(pattern: string): seq[string] {.inline.} =
  var i = 0
  while i < pattern.len:
    if pattern[i] == ':':
      inc i
      var name = ""
      while i < pattern.len and pattern[i] != '/':
        name.add(pattern[i])
        inc i
      if isValidOpenApiParamName(name):
        result.add(name)
    else:
      inc i

proc buildSpec(registry: OpenApiRegistry, options: var OpenApiOptions): JsonNode =
  var info = %*{
    "title": options.info.title,
    "version": options.info.version
  }
  if options.info.description.len > 0:
    info["description"] = %options.info.description
  if options.info.contact.name.len > 0 or options.info.contact.email.len > 0:
    var contact = newJObject()
    if options.info.contact.name.len > 0:
      contact["name"] = %options.info.contact.name
    if options.info.contact.url.len > 0:
      contact["url"] = %options.info.contact.url
    if options.info.contact.email.len > 0:
      contact["email"] = %options.info.contact.email
    info["contact"] = contact

  var paths = newJObject()
  for route in registry.routes:
    let key = docKey(route.httpMethod, route.pattern)
    let openApiPath = convertPatternToOpenApi(route.pattern)
    if not paths.hasKey(openApiPath):
      paths[openApiPath] = newJObject()

    var operation = newJObject()
    if registry.docs.hasKey(key):
      let doc = registry.docs[key]
      if doc.summary.len > 0:
        operation["summary"] = %doc.summary
      if doc.description.len > 0:
        operation["description"] = %doc.description
      if doc.tags.len > 0:
        operation["tags"] = %doc.tags
      if doc.operationId.len > 0:
        operation["operationId"] = %doc.operationId
      if doc.deprecated:
        operation["deprecated"] = %true

      var params = newJArray()
      let pathParams = extractPathParams(route.pattern)
      for paramName in pathParams:
        params.add(%*{
          "name": paramName,
          "in": "path",
          "required": true,
          "schema": {"type": "string"}
        })
      for param in doc.parameters:
        params.add(%*{
          "name": param.name,
          "in": param.location,
          "required": param.required,
          "description": param.description,
          "schema": {"type": if param.schema.len > 0: param.schema else: "string"}
        })
      if params.len > 0:
        operation["parameters"] = params

      if doc.requestBodyContentType.len > 0:
        operation["requestBody"] = %*{
          "description": if doc.requestBodyDescription.len > 0: doc.requestBodyDescription else: "",
          "content": {
            doc.requestBodyContentType: {
              "schema": {"type": "object"}
            }
          }
        }

      let respDesc = if doc.responseDescription.len > 0: doc.responseDescription else: "Successful response"
      let respCt = if doc.responseContentType.len > 0: doc.responseContentType else: "application/json"
      operation["responses"] = %*{
        "200": {
          "description": respDesc,
          "content": {
            respCt: {
              "schema": {"type": "object"}
            }
          }
        }
      }
    else:
      let pathParams = extractPathParams(route.pattern)
      if pathParams.len > 0:
        var params = newJArray()
        for paramName in pathParams:
          params.add(%*{
            "name": paramName,
            "in": "path",
            "required": true,
            "schema": {"type": "string"}
          })
        operation["parameters"] = params
      operation["responses"] = %*{
        "200": {"description": "Successful response"}
      }

    paths[openApiPath][route.httpMethod.toLowerAscii()] = operation

  var spec = %*{
    "openapi": "3.0.3",
    "info": info,
    "paths": paths
  }

  if options.servers.len > 0:
    var servers = newJArray()
    for url in options.servers:
      servers.add(%*{"url": url})
    spec["servers"] = servers

  spec

const SwaggerUiHtml = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>API Documentation</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css"/>
</head>
<body>
<div id="swagger-ui"></div>
<script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
<script>
SwaggerUIBundle({url:"{{SPEC_URL}}",dom_id:"#swagger-ui",presets:[SwaggerUIBundle.presets.apis,SwaggerUIBundle.SwaggerUIStandalonePreset],layout:"BaseLayout"});
</script>
</body>
</html>"""

## NOTE: The returned middleware is NOT thread-safe: the spec cache is
## closure-local. In runThreaded mode, create one instance per thread, or
## prefer runCluster()/runAuto() (separate processes) for shared use.
proc openapi*(
  registry: OpenApiRegistry,
  options: OpenApiOptions = defaultOpenApiOptions()
): AsyncMiddleware =
  var opts = options
  let reg = if registry == nil: newOpenApiRegistry() else: registry
  let specPath = if opts.specPath.len > 0: opts.specPath else: "/api-docs/openapi.json"
  let uiPath = if opts.uiPath.len > 0: opts.uiPath else: "/api-docs"
  let uiHtml = SwaggerUiHtml.replace("{{SPEC_URL}}", specPath)
  var cachedSpec = ""
  var cachedVersion = -1

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if req.methodKind != hmGet:
      await next()
      return

    let path = $req.path
    let normalizedPath = if path.len > 1 and path[^1] == '/': path[0 .. ^2] else: path

    if normalizedPath == specPath:
      if cachedVersion != reg.version:
        cachedSpec = $buildSpec(reg, opts)
        cachedVersion = reg.version
      res.set("Content-Type", "application/json; charset=utf-8")
      res.set("Cache-Control", "no-cache")
      res.set("ETag", "\"" & $reg.version & "\"")
      res.send(cachedSpec)
      return

    if normalizedPath == uiPath:
      res.set("Content-Type", "text/html; charset=utf-8")
      res.set("Cache-Control", "no-cache")
      res.send(uiHtml)
      return

    await next()
