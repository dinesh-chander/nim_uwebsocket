import std/[monotimes, os, strutils, times, formatfloat]
import jsony

import ../../nim_fastjson

let fastJson = initFastJson()

template serialize(value: untyped): untyped =
  fastJson.serialize(value)

template deserialize(json: untyped, T: typedesc): untyped =
  fastJson.deserialize(json, T)

# === Deep nested types modeling realistic API responses ===

# --- E-commerce order (medium, 3-level nesting) ---
type
  Money = object
    amount: float64
    currency: string

  OrderItem = object
    sku: string
    name: string
    quantity: int
    unitPrice: Money
    discount: float64

  ShippingAddress = object
    line1: string
    line2: string
    city: string
    state: string
    postalCode: string
    country: string

  OrderPayment = object
    paymentMethod: string
    last4: string
    status: string
    transactionId: string

  Order = object
    orderId: string
    customerId: int
    status: string
    items: seq[OrderItem]
    shipping: ShippingAddress
    payment: OrderPayment
    subtotal: Money
    tax: Money
    total: Money
    createdAt: string

  OrdersPage = object
    orders: seq[Order]
    totalCount: int
    page: int
    pageSize: int

# --- GitHub-like API response (deep nesting, many string fields) ---
type
  GitUser = object
    login: string
    id: int
    avatarUrl: string
    profileUrl: string

  GitLabel = object
    id: int
    name: string
    color: string
    description: string

  GitMilestone = object
    id: int
    number: int
    title: string
    state: string
    openIssues: int
    closedIssues: int

  GitIssue = object
    id: int
    number: int
    title: string
    body: string
    state: string
    user: GitUser
    labels: seq[GitLabel]
    milestone: GitMilestone
    assignees: seq[GitUser]
    comments: int
    createdAt: string
    updatedAt: string

  GitIssuesResponse = object
    issues: seq[GitIssue]
    totalCount: int
    incomplete: bool

# --- Analytics dashboard (wide + deep, many numeric fields) ---
type
  GeoBreakdown = object
    country: string
    sessions: int
    pageviews: int
    bounceRate: float64
    avgDuration: float64

  DeviceBreakdown = object
    deviceType: string
    browser: string
    sessions: int
    conversionRate: float64

  TrafficSource = object
    source: string
    medium: string
    campaign: string
    sessions: int
    revenue: float64
    transactions: int

  DayMetrics = object
    date: string
    sessions: int
    users: int
    newUsers: int
    pageviews: int
    bounceRate: float64
    avgSessionDuration: float64
    goalCompletions: int
    revenue: float64
    transactions: int
    geo: seq[GeoBreakdown]
    devices: seq[DeviceBreakdown]
    sources: seq[TrafficSource]

  AnalyticsDashboard = object
    siteId: string
    dateRange: string
    days: seq[DayMetrics]
    totalSessions: int
    totalRevenue: float64

# --- Config tree (deeply nested, heterogeneous) ---
type
  RateLimitConfig = object
    requestsPerSecond: int
    burstSize: int
    windowMs: int

  RetryConfig = object
    maxAttempts: int
    initialDelayMs: int
    maxDelayMs: int
    backoffMultiplier: float64

  EndpointConfig = object
    path: string
    httpMethod: string
    timeout: int
    rateLimit: RateLimitConfig
    retry: RetryConfig
    headers: seq[string]
    cacheTtlSec: int
    authenticated: bool

  ServiceConfig = object
    name: string
    version: string
    host: string
    port: int
    endpoints: seq[EndpointConfig]
    healthCheckPath: string
    logLevel: string

  ClusterConfig = object
    services: seq[ServiceConfig]
    region: string
    environment: string

# === Data generators ===

proc sampleOrder(i: int): Order =
  Order(
    orderId: "ORD-" & $((i + 1) * 1000),
    customerId: 10000 + i,
    status: if (i mod 3) == 0: "shipped" elif (i mod 3) == 1: "processing" else: "delivered",
    items: @[
      OrderItem(sku: "SKU-" & $(i * 10 + 1), name: "Widget Pro " & $i, quantity: 2,
                unitPrice: Money(amount: 29.99 + float64(i) * 0.5, currency: "USD"), discount: 0.1),
      OrderItem(sku: "SKU-" & $(i * 10 + 2), name: "Gadget Plus " & $i, quantity: 1,
                unitPrice: Money(amount: 49.99, currency: "USD"), discount: 0.0),
      OrderItem(sku: "SKU-" & $(i * 10 + 3), name: "Accessory " & $i, quantity: 3,
                unitPrice: Money(amount: 9.99, currency: "USD"), discount: 0.15),
    ],
    shipping: ShippingAddress(line1: $(100 + i) & " Commerce Blvd", line2: "Suite " & $(i + 1),
                              city: "Portland", state: "OR", postalCode: "9720" & $(i mod 10), country: "US"),
    payment: OrderPayment(paymentMethod: "card", last4: "424" & $(i mod 10), status: "captured",
                          transactionId: "txn_" & $(100000 + i)),
    subtotal: Money(amount: 129.95 + float64(i), currency: "USD"),
    tax: Money(amount: 10.40, currency: "USD"),
    total: Money(amount: 140.35 + float64(i), currency: "USD"),
    createdAt: "2025-01-" & $(10 + (i mod 20)) & "T10:30:00Z",
  )

proc sampleOrders(count: int): OrdersPage =
  result.totalCount = count * 10
  result.page = 1
  result.pageSize = count
  result.orders = newSeq[Order](count)
  for i in 0..<count:
    result.orders[i] = sampleOrder(i)

proc sampleGitIssue(i: int): GitIssue =
  let body = "This is issue #" & $i & ". It describes a problem with the frobnicator module. " &
    "Steps to reproduce:\n1. Open the dashboard\n2. Click on settings\n3. Toggle the feature flag\n" &
    "Expected: Feature activates\nActual: Nothing happens and console shows an error."
  GitIssue(
    id: 1000 + i, number: i + 1,
    title: "Bug: frobnicator fails when feature flag is toggled (issue " & $i & ")",
    body: body, state: if (i mod 4) == 0: "closed" else: "open",
    user: GitUser(login: "dev" & $i, id: 5000 + i,
                  avatarUrl: "https://avatars.example.com/" & $i & ".png",
                  profileUrl: "https://github.example.com/dev" & $i),
    labels: @[
      GitLabel(id: 100 + i, name: "bug", color: "d73a4a", description: "Something isn't working"),
      GitLabel(id: 200 + i, name: "priority:high", color: "e11d48", description: "High priority item"),
    ],
    milestone: GitMilestone(id: 10 + (i mod 5), number: (i mod 5) + 1,
                            title: "v2." & $(i mod 5) & " release",
                            state: "open", openIssues: 10 - (i mod 5), closedIssues: 5 + (i mod 5)),
    assignees: @[
      GitUser(login: "reviewer" & $i, id: 8000 + i,
              avatarUrl: "https://avatars.example.com/r" & $i & ".png",
              profileUrl: "https://github.example.com/reviewer" & $i),
    ],
    comments: i * 3 + 1,
    createdAt: "2025-02-" & $(1 + (i mod 28)) & "T09:00:00Z",
    updatedAt: "2025-03-" & $(1 + (i mod 28)) & "T14:30:00Z",
  )

proc sampleGitIssues(count: int): GitIssuesResponse =
  result.totalCount = count * 5
  result.incomplete = false
  result.issues = newSeq[GitIssue](count)
  for i in 0..<count:
    result.issues[i] = sampleGitIssue(i)

proc sampleDayMetrics(i: int): DayMetrics =
  DayMetrics(
    date: "2025-01-" & $(1 + i),
    sessions: 5000 + i * 100,
    users: 3000 + i * 60,
    newUsers: 500 + i * 10,
    pageviews: 15000 + i * 300,
    bounceRate: 0.35 + float64(i) * 0.005,
    avgSessionDuration: 120.5 + float64(i) * 2.3,
    goalCompletions: 200 + i * 5,
    revenue: 5000.0 + float64(i) * 150.0,
    transactions: 100 + i * 3,
    geo: @[
      GeoBreakdown(country: "US", sessions: 3000 + i * 50, pageviews: 9000 + i * 150,
                   bounceRate: 0.32, avgDuration: 130.0),
      GeoBreakdown(country: "GB", sessions: 800 + i * 20, pageviews: 2400 + i * 60,
                   bounceRate: 0.38, avgDuration: 110.0),
      GeoBreakdown(country: "DE", sessions: 500 + i * 10, pageviews: 1500 + i * 30,
                   bounceRate: 0.40, avgDuration: 105.0),
    ],
    devices: @[
      DeviceBreakdown(deviceType: "desktop", browser: "Chrome", sessions: 2500 + i * 40,
                      conversionRate: 0.042),
      DeviceBreakdown(deviceType: "mobile", browser: "Safari", sessions: 1800 + i * 35,
                      conversionRate: 0.028),
      DeviceBreakdown(deviceType: "tablet", browser: "Chrome", sessions: 400 + i * 10,
                      conversionRate: 0.035),
    ],
    sources: @[
      TrafficSource(source: "google", medium: "organic", campaign: "",
                    sessions: 2000 + i * 30, revenue: 2500.0 + float64(i) * 80.0, transactions: 50 + i),
      TrafficSource(source: "facebook", medium: "cpc", campaign: "spring_sale",
                    sessions: 1000 + i * 20, revenue: 1500.0 + float64(i) * 50.0, transactions: 30 + i),
      TrafficSource(source: "direct", medium: "none", campaign: "",
                    sessions: 1500 + i * 25, revenue: 800.0 + float64(i) * 20.0, transactions: 20 + i),
    ],
  )

proc sampleDashboard(days: int): AnalyticsDashboard =
  result.siteId = "site_abc123"
  result.dateRange = "2025-01-01/2025-01-" & $(days)
  result.totalSessions = 150000
  result.totalRevenue = 150000.0
  result.days = newSeq[DayMetrics](days)
  for i in 0..<days:
    result.days[i] = sampleDayMetrics(i)

proc sampleEndpoint(i: int): EndpointConfig =
  EndpointConfig(
    path: "/api/v2/resource" & $i,
    httpMethod: if (i mod 3) == 0: "GET" elif (i mod 3) == 1: "POST" else: "PUT",
    timeout: 5000 + (i mod 5) * 1000,
    rateLimit: RateLimitConfig(requestsPerSecond: 100 + i * 10, burstSize: 200 + i * 20, windowMs: 60000),
    retry: RetryConfig(maxAttempts: 3, initialDelayMs: 100, maxDelayMs: 5000, backoffMultiplier: 2.0),
    headers: @["X-Request-Id", "X-Trace-Id", "Authorization"],
    cacheTtlSec: 300 * (1 + i mod 4),
    authenticated: (i mod 2) == 0,
  )

proc sampleCluster(numServices, endpointsPerService: int): ClusterConfig =
  result.region = "us-east-1"
  result.environment = "production"
  result.services = newSeq[ServiceConfig](numServices)
  for i in 0..<numServices:
    var endpoints = newSeq[EndpointConfig](endpointsPerService)
    for j in 0..<endpointsPerService:
      endpoints[j] = sampleEndpoint(i * endpointsPerService + j)
    result.services[i] = ServiceConfig(
      name: "service-" & $i,
      version: "2." & $(i mod 10) & ".0",
      host: "svc-" & $i & ".internal",
      port: 8000 + i,
      endpoints: endpoints,
      healthCheckPath: "/health",
      logLevel: "info",
    )

# === Benchmark harness ===

proc bench(name: string, iterations: int, op: proc()): tuple[opsPerSec: float64, nsPerOp: float64] =
  for _ in 0..min(100, iterations div 10):
    op()
  let start = getMonoTime()
  for _ in 0..<iterations:
    op()
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let ops = float(iterations) / (float(elapsedNs) / 1_000_000_000.0)
  let nsOp = float(elapsedNs) / float(iterations)
  (ops, nsOp)

proc fmtOps(ops: float64): string =
  if ops >= 1_000_000:
    formatFloat(ops / 1_000_000.0, ffDecimal, 2) & "M"
  elif ops >= 1_000:
    formatFloat(ops / 1_000.0, ffDecimal, 1) & "K"
  else:
    formatFloat(ops, ffDecimal, 0)

proc fmtNs(ns: float64): string =
  if ns >= 1_000_000:
    formatFloat(ns / 1_000_000.0, ffDecimal, 1) & "ms"
  elif ns >= 1_000:
    formatFloat(ns / 1_000.0, ffDecimal, 1) & "us"
  else:
    formatFloat(ns, ffDecimal, 0) & "ns"

proc fmtBytes(b: int): string =
  if b >= 1_048_576:
    formatFloat(float(b) / 1_048_576.0, ffDecimal, 1) & "MB"
  elif b >= 1024:
    formatFloat(float(b) / 1024.0, ffDecimal, 1) & "KB"
  else:
    $b & "B"

proc runPair(label: string, iterations: int, jsonyOp: proc(), fastjsonOp: proc(), jsonBytes: int) =
  let (jOps, jNs) = bench("jsony", iterations, jsonyOp)
  let (fOps, fNs) = bench("fastjson", iterations, fastjsonOp)
  let speedup = fOps / jOps
  let pad = 48 - label.len
  echo label, spaces(max(1, pad)),
    "jsony: ", fmtOps(jOps).align(8), " (", fmtNs(jNs).align(7), ")  ",
    "fastjson: ", fmtOps(fOps).align(8), " (", fmtNs(fNs).align(7), ")  ",
    formatFloat(speedup, ffDecimal, 2), "x",
    "  [", fmtBytes(jsonBytes), "]"

when isMainModule:
  let iterations =
    if paramCount() > 0: parseInt(paramStr(1))
    else: 20000

  echo "=== nim_fastjson benchmark: medium & large nested JSON ==="
  echo "iterations: ", iterations
  echo ""

  # -------------------------------------------------------
  echo "--- SERIALIZE ---"
  echo ""

  # Medium: e-commerce orders (3-level, 10 orders x 3 items each)
  block:
    let data = sampleOrders(10)
    let json = jsony.toJson(data)
    runPair("orders 10x3items (3-level nest)", iterations,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  # Large: e-commerce orders (50 orders)
  block:
    let data = sampleOrders(50)
    let json = jsony.toJson(data)
    runPair("orders 50x3items", iterations div 2,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  # Medium: GitHub issues (10 issues, nested user/labels/milestone)
  block:
    let data = sampleGitIssues(10)
    let json = jsony.toJson(data)
    runPair("github issues 10 (4-level nest)", iterations,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  # Large: GitHub issues (50 issues)
  block:
    let data = sampleGitIssues(50)
    let json = jsony.toJson(data)
    runPair("github issues 50", iterations div 2,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  # Medium: analytics dashboard (7 days, each with 3 geo + 3 device + 3 source)
  block:
    let data = sampleDashboard(7)
    let json = jsony.toJson(data)
    runPair("analytics 7-day (nested arrays)", iterations,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  # Large: analytics dashboard (30 days)
  block:
    let data = sampleDashboard(30)
    let json = jsony.toJson(data)
    runPair("analytics 30-day", iterations div 2,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  # Medium: config tree (3 services x 4 endpoints)
  block:
    let data = sampleCluster(3, 4)
    let json = jsony.toJson(data)
    runPair("config 3svc x 4endpoints (4-level)", iterations,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  # Large: config tree (10 services x 8 endpoints)
  block:
    let data = sampleCluster(10, 8)
    let json = jsony.toJson(data)
    runPair("config 10svc x 8endpoints", iterations div 2,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  # XL: orders 200
  block:
    let data = sampleOrders(200)
    let json = jsony.toJson(data)
    runPair("orders 200 (XL)", iterations div 5,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  # XL: analytics 90-day
  block:
    let data = sampleDashboard(90)
    let json = jsony.toJson(data)
    runPair("analytics 90-day (XL)", iterations div 5,
      proc() = discard jsony.toJson(data),
      proc() = discard serialize(data),
      json.len)

  echo ""
  echo "--- DESERIALIZE ---"
  echo ""

  block:
    let json = jsony.toJson(sampleOrders(10))
    runPair("orders 10x3items (3-level nest)", iterations,
      proc() = discard jsony.fromJson(json, OrdersPage),
      proc() = discard deserialize(json, OrdersPage),
      json.len)

  block:
    let json = jsony.toJson(sampleOrders(50))
    runPair("orders 50x3items", iterations div 2,
      proc() = discard jsony.fromJson(json, OrdersPage),
      proc() = discard deserialize(json, OrdersPage),
      json.len)

  block:
    let json = jsony.toJson(sampleGitIssues(10))
    runPair("github issues 10 (4-level nest)", iterations,
      proc() = discard jsony.fromJson(json, GitIssuesResponse),
      proc() = discard deserialize(json, GitIssuesResponse),
      json.len)

  block:
    let json = jsony.toJson(sampleGitIssues(50))
    runPair("github issues 50", iterations div 2,
      proc() = discard jsony.fromJson(json, GitIssuesResponse),
      proc() = discard deserialize(json, GitIssuesResponse),
      json.len)

  block:
    let json = jsony.toJson(sampleDashboard(7))
    runPair("analytics 7-day (nested arrays)", iterations,
      proc() = discard jsony.fromJson(json, AnalyticsDashboard),
      proc() = discard deserialize(json, AnalyticsDashboard),
      json.len)

  block:
    let json = jsony.toJson(sampleDashboard(30))
    runPair("analytics 30-day", iterations div 2,
      proc() = discard jsony.fromJson(json, AnalyticsDashboard),
      proc() = discard deserialize(json, AnalyticsDashboard),
      json.len)

  block:
    let json = jsony.toJson(sampleCluster(3, 4))
    runPair("config 3svc x 4endpoints (4-level)", iterations,
      proc() = discard jsony.fromJson(json, ClusterConfig),
      proc() = discard deserialize(json, ClusterConfig),
      json.len)

  block:
    let json = jsony.toJson(sampleCluster(10, 8))
    runPair("config 10svc x 8endpoints", iterations div 2,
      proc() = discard jsony.fromJson(json, ClusterConfig),
      proc() = discard deserialize(json, ClusterConfig),
      json.len)

  block:
    let json = jsony.toJson(sampleOrders(200))
    runPair("orders 200 (XL)", iterations div 5,
      proc() = discard jsony.fromJson(json, OrdersPage),
      proc() = discard deserialize(json, OrdersPage),
      json.len)

  block:
    let json = jsony.toJson(sampleDashboard(90))
    runPair("analytics 90-day (XL)", iterations div 5,
      proc() = discard jsony.fromJson(json, AnalyticsDashboard),
      proc() = discard deserialize(json, AnalyticsDashboard),
      json.len)
