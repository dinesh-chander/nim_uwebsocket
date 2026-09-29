import std/[json, tables, os]
import nim_fasthttpclient/types as fasttypes
import nim_fasthttpclient/client as fastclient
import ../../../nim_usockets/src/nim_usockets/usockets

export fasttypes.HttpClient, fasttypes.HttpClientConfig, fasttypes.HttpHeader,
       fasttypes.defaultHttpClientConfig
export fastclient.newHttpClientFromConfig, fastclient.initClientWithLoop

type
  HttpClientRegistry* = object
    clients*: Table[string, ptr fasttypes.HttpClient]
    configs*: Table[string, HttpClientConfig]

## Parse a ``JsonNode`` into an ``HttpClientConfig``, clamping numeric limits and filling defaults for missing fields.
proc parseHttpClientConfig*(j: JsonNode): HttpClientConfig =
  result = defaultHttpClientConfig()
  if j == nil or j.kind != JObject:
    return
  if j.hasKey("maxConnsPerHost"):
    result.maxConnsPerHost = max(1, j["maxConnsPerHost"].getInt)
  if j.hasKey("requestTimeoutMs"):
    result.requestTimeoutMs = max(1, j["requestTimeoutMs"].getInt)
  if j.hasKey("connectTimeoutMs"):
    result.connectTimeoutMs = max(1, j["connectTimeoutMs"].getInt)
  if j.hasKey("keepAliveTimeoutMs"):
    result.keepAliveTimeoutMs = max(0, j["keepAliveTimeoutMs"].getInt)
  if j.hasKey("maxRetries"):
    result.maxRetries = max(0, j["maxRetries"].getInt)
  if j.hasKey("retryDelayMs"):
    result.retryDelayMs = max(0, j["retryDelayMs"].getInt)
  if j.hasKey("preferH2"):
    result.preferH2 = j["preferH2"].getBool
  if j.hasKey("retryOnStatusCodes"):
    result.retryOnStatusCodes = @[]
    for item in j["retryOnStatusCodes"]:
      let code = item.getInt
      if code >= 100 and code <= 599:
        result.retryOnStatusCodes.add code
  if j.hasKey("defaultHeaders"):
    let headersNode = j["defaultHeaders"]
    if headersNode.kind == JObject:
      for key, val in headersNode:
        result.defaultHeaders.add fasttypes.HttpHeader(name: key, value: val.getStr)

## Create an empty ``HttpClientRegistry`` with preallocated client and config tables.
proc initRegistry*(): HttpClientRegistry =
  result.clients = initTable[string, ptr fasttypes.HttpClient](8)
  result.configs = initTable[string, HttpClientConfig](8)

## Load named ``HttpClient`` entries from a JSON config file into a fresh ``HttpClientRegistry``.
proc loadHttpClients*(configPath: string): HttpClientRegistry =
  result = initRegistry()
  if not fileExists(configPath):
    return
  var root: JsonNode
  try:
    let raw = readFile(configPath)
    root = parseJson(raw)
  except CatchableError:
    return
  if root == nil or root.kind != JObject or not root.hasKey("httpClients"):
    return
  let clientsNode = root["httpClients"]
  if clientsNode.kind != JObject:
    return
  for name, clientJson in clientsNode:
    if name.len == 0:
      continue
    let config = parseHttpClientConfig(clientJson)
    result.configs[name] = config
    let clientPtr = cast[ptr fasttypes.HttpClient](alloc0(sizeof(fasttypes.HttpClient)))
    clientPtr[] = newHttpClientFromConfig(config)
    result.clients[name] = clientPtr

## Bind each loaded client to the given event loop, skipping clients that are already initialized.
proc initRegistryClients*(registry: var HttpClientRegistry, loop: UsLoopPtr) =
  for name in registry.clients.keys:
    let clientPtr = registry.clients[name]
    if not clientPtr.initialized and loop != nil:
      fastclient.initClientWithLoop(clientPtr[], loop)

## Look up a named client in the ``HttpClientRegistry``, returning ``nil`` if the name is unknown.
proc getClient*(registry: HttpClientRegistry, name: string): ptr fasttypes.HttpClient =
  if name in registry.clients:
    return registry.clients[name]
  nil

## Close and deallocate every client in the ``HttpClientRegistry``, then clear its tables.
proc closeAll*(registry: var HttpClientRegistry) =
  for name in registry.clients.keys:
    let clientPtr = registry.clients[name]
    try:
      fastclient.close(clientPtr[])
    except CatchableError:
      discard
    dealloc(clientPtr)
  registry.clients.clear()
  registry.configs.clear()
