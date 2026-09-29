# Express.js Optimization Plan

## Benchmark Results (Express 5.2.1, Node 22.22.1, macOS ARM64)

**Test parameters:** `wrk -t8 -c256 -d5s --latency`

| Endpoint   | Req/sec   | Avg Latency | p50      | p90      | p99       | Transfer/sec |
|------------|-----------|-------------|----------|----------|-----------|-------------|
| /json      | 16,021    | 64.46ms     | 14.71ms  | 70.84ms  | 993.10ms  | 4.77 MB/s   |
| /plaintext | 16,554    | 63.96ms     | 14.39ms  | 25.91ms  | 1.05s     | 3.80 MB/s   |

**Reference:** nim_express single process achieves ~95k req/s on the same hardware — **~6x faster**.

---

## V8 Profiling Summary

8,331 total ticks sampled. **83.9% (6,989 ticks) spent in UNKNOWN** — this means most time is in native C/C++ code (kernel syscalls, libuv I/O, TCP stack), not in JavaScript. Only 16.1% of CPU time is in JS.

### Top JS Bottlenecks (Bottom-Up, by tick count)

| Ticks | % of total | Function | Category |
|-------|-----------|----------|----------|
| 831   | 11.9%     | `clearBuffer` (writable stream) | **Stream I/O** |
| 509   | 7.3%      | `app()` (Express dispatch entry) | **Routing** |
| 484   | 6.9%      | `writeHead` (HTTP header serialization) | **HTTP headers** |
| 461   | 6.6%      | `next()` (router middleware chain) | **Routing** |
| 271   | 3.9%      | `end()` (_http_outgoing) | **Stream I/O** |
| 245   | 3.5%      | `_storeHeader` (header string building) | **HTTP headers** |
| 207   | 3.0%      | `write_` (_http_outgoing) | **Stream I/O** |
| 195   | 2.8%      | `send()` (express/response.js) | **Response** |
| 194   | 2.8%      | `resOnFinish` (request cleanup) | **Lifecycle** |
| 189   | 2.7%      | `_send` (_http_outgoing) | **Stream I/O** |
| 180   | 2.6%      | `Readable.on` (event listener setup) | **Lifecycle** |
| 165   | 2.4%      | `entitytag` (ETag generation) | **ETag** |
| 161   | 2.3%      | `header()` (express set header) | **HTTP headers** |

### GC Pressure

401 ticks (4.8%) in garbage collection — significant for a simple benchmark.

### Regex in Hot Path

Multiple regex patterns appear in profiling:
- `[^\t\x20-\x7e\x80-\xff]` — header validation
- `^[\^_\`a-zA-Z\-0-9!#$%&'*+.|~]+$` — header name validation
- `^[!#$%&'*+.^_\`|~0-9A-Za-z-]+\/[!#$%&'*+.^_\`|~0-9A-Za-z-]+$` — content-type validation
- `^\s*([^;\s]*)(?:;|\s|$)` — content-type parsing

---

## Bottleneck Analysis

### 1. Native I/O Dominance (83.9% UNKNOWN)

The single biggest bottleneck is **not JavaScript** — it's the Node.js HTTP stack itself:
- `http.createServer` uses `net.Socket` (libuv TCP) + Node.js Streams
- Every request creates `IncomingMessage` (Readable) + `ServerResponse` (Writable) stream objects
- Multiple syscalls per request: accept, read, write, close
- Stream buffering/corking/uncorking adds overhead per write

**Root cause:** Node's `http` module wraps TCP sockets in full Duplex streams with backpressure, event emission, and buffering — all unnecessary for simple request/response.

### 2. Stream Write Pipeline (24.5% of JS ticks)

The response write path is deeply layered:
```
res.send() → res.end() → write_() → _send() → clearBuffer() → socket.write()
```

Each layer adds:
- Argument validation
- Buffer conversion/encoding
- Cork/uncork cycles
- Callback scheduling via `nextTick`

### 3. HTTP Header Serialization (12.7% of JS ticks)

`writeHead` + `_storeHeader` serialize headers on every response:
- Iterates all headers, validates each name/value with regex
- Builds header string via string concatenation
- Converts status code to string each time
- Checks for content-length, transfer-encoding, date header

### 4. Router/Middleware Dispatch (13.9% of JS ticks)

`app()` → `router.handle()` → `next()` loop:
- Creates closures per request for the middleware chain
- Layer matching involves regex test per route per request
- `processParams` runs even with no route params
- `restore()` called to reset req.url after each layer

### 5. ETag Generation (2.4% of JS ticks)

`entitytag()` runs on **every response** via `res.send()`:
- Computes a weak ETag using `crypto.createHash('sha1')`
- Converts body to buffer, hashes it, base64-encodes
- Result is set as header but almost never used by benchmark clients

### 6. Per-Request Object Allocation (drives 4.8% GC)

Every request creates:
- `IncomingMessage` object (extends Readable stream)
- `ServerResponse` object (extends Writable stream)
- Multiple closures for middleware chain
- Buffer objects for response body
- String concatenations for headers

---

## Optimization Plan

### Phase 1: Quick Wins (No architecture changes)

#### 1.1 Disable ETag generation
```js
app.set('etag', false);
```
**Expected gain:** ~3-5% throughput. Eliminates SHA1 hash per response.

#### 1.2 Disable X-Powered-By header
```js
app.disable('x-powered-by');
```
**Expected gain:** ~1%. One fewer header to serialize.

#### 1.3 Pre-serialize static responses
```js
// For plaintext, pre-compute the buffer
const plaintextBuf = Buffer.from('Hello, World!');
app.get('/plaintext', (req, res) => {
  res.writeHead(200, {
    'content-type': 'text/plain',
    'content-length': plaintextBuf.length
  });
  res.end(plaintextBuf);
});
```
**Expected gain:** ~5-10%. Bypasses Express `send()` pipeline entirely.

#### 1.4 Use `res.writeHead` + `res.end` instead of `res.json`
```js
app.get('/json', (req, res) => {
  const body = JSON.stringify({
    message: 'Hello, World!',
    timestamp: Math.floor(Date.now() / 1000),
    id: Math.floor(Math.random() * 999999) + 1,
    success: true
  });
  res.writeHead(200, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(body)
  });
  res.end(body);
});
```
**Expected gain:** ~5-10%. Skips `send()` overhead (etag, charset detection, content-type negotiation).

### Phase 2: Alternative Frameworks (Drop-in replacements)

#### 2.1 Use Fastify instead of Express
```js
const fastify = require('fastify')({ logger: false });

fastify.get('/json', (req, reply) => {
  reply.send({
    message: 'Hello, World!',
    timestamp: Math.floor(Date.now() / 1000),
    id: Math.floor(Math.random() * 999999) + 1,
    success: true
  });
});
```
**Expected gain:** 2-3x throughput (~35-50k req/s). Fastify uses:
- Schema-based serialization (fast-json-stringify)
- Radix tree router (find-my-way) instead of regex
- Minimal per-request allocations
- Reusable reply objects

#### 2.2 Use uWebSockets.js directly
```js
const uWS = require('uWebSockets.js');

uWS.App().get('/json', (res, req) => {
  res.writeHeader('content-type', 'application/json');
  res.end(JSON.stringify({ message: 'Hello, World!' }));
}).listen(3005, () => {});
```
**Expected gain:** 5-8x throughput (~80-130k req/s). Bypasses Node's HTTP/stream stack entirely.

#### 2.3 Use ultimate-express (already in project)
Already benchmarked — sits between Express and raw uWS by providing Express API over uWebSockets.js.

### Phase 3: Node.js Runtime Tuning

#### 3.1 Increase libuv thread pool
```bash
UV_THREADPOOL_SIZE=16 node bench_express.js
```

#### 3.2 Use `--max-semi-space-size` to reduce GC pauses
```bash
node --max-semi-space-size=64 bench_express.js
```
**Expected gain:** Reduces p99 tail latency by reducing young-gen GC frequency.

#### 3.3 Use cluster module for multi-core
```js
const cluster = require('cluster');
const os = require('os');

if (cluster.isPrimary) {
  for (let i = 0; i < os.cpus().length; i++) cluster.fork();
} else {
  // ... express app
}
```
**Expected gain:** ~3-4x throughput on multi-core (linear scaling up to core count, limited by single event loop per process).

### Phase 4: Deep Optimizations (If staying with Express)

#### 4.1 Replace `JSON.stringify` with `fast-json-stringify`
```js
const fastJson = require('fast-json-stringify');
const stringify = fastJson({
  type: 'object',
  properties: {
    message: { type: 'string' },
    timestamp: { type: 'integer' },
    id: { type: 'integer' },
    success: { type: 'boolean' }
  }
});
```
**Expected gain:** ~2-3x faster serialization for known schemas.

#### 4.2 HTTP connection keep-alive tuning
```js
const server = app.listen(3005);
server.keepAliveTimeout = 72000;
server.headersTimeout = 73000;
```

#### 4.3 Pre-compute Date header (refreshed every second)
The `Date` HTTP header is generated per-response. Cache it:
```js
let dateHeader = new Date().toUTCString();
setInterval(() => { dateHeader = new Date().toUTCString(); }, 1000);

app.use((req, res, next) => {
  res.setHeader('Date', dateHeader);
  next();
});
```

---

## Expected Results Summary

| Optimization Level | Est. Req/sec | vs Baseline |
|-------------------|-------------|-------------|
| Baseline Express  | ~16,500     | 1x          |
| Phase 1 (quick wins) | ~22,000 | 1.3x        |
| Phase 2a (Fastify)   | ~45,000 | 2.7x        |
| Phase 2b (uWS.js)    | ~100,000+ | 6x+       |
| Phase 3 (clustering)  | ~55,000 | 3.3x (4 cores) |
| Phase 1+3 combined    | ~75,000 | 4.5x        |

---

## Key Takeaway

Express's bottleneck is architectural, not algorithmic. The Node.js `http` module + Streams abstraction accounts for **~84% of CPU time**. The Express middleware layer adds another ~14% in JS overhead. Only ~2% is actual application code.

To match nim_express performance (~95k req/s), you must bypass Node's HTTP stack entirely (uWebSockets.js) or use a framework that minimizes the abstraction layers (Fastify).
