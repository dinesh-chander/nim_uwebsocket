## GPU + inference-engine collectors for the GPU dashboard example.
##
## Port of the collector half of gpu-stats-server.js (Node sidecar):
## vendor SMI runners (amd-smi / nvidia-smi, or FAKE_SMI_DIR fixtures),
## Prometheus text parsing for llama.cpp `/metrics`, and rate computation
## across samples. All procs here are blocking — call them via `runOffload`.

import std/[json, os, osproc, sequtils, streams, strutils, tables, times, math]
import std/httpclient except Response

export json, os, strutils, tables, times

const
  SmiTimeoutSecs* = 8
  HttpTimeoutMs* = 8000
  PropsTtlMs* = 60_000

type
  OptF* = (bool, float)   # present + value — mirrors JS num() null handling
  OptS* = (bool, string)  # present + value

const SmiCmds = {
  "amd.metric": ("amd-smi", @["metric", "--json"]),
  "amd.static": ("amd-smi", @["static", "--json"]),
  "nvidia": ("nvidia-smi", @[
    "--query-gpu=index,name,temperature.gpu,utilization.gpu,memory.used," &
    "memory.total,power.draw,power.limit,clocks.current.sm,clocks.current.memory",
    "--format=csv,noheader,nounits"]),
}.toTable

proc runSmiBlocking*(kind: string, fakeDir: string, timeoutExe: string): string =
  ## Runs one vendor SMI command (or reads a FAKE_SMI_DIR fixture) and returns
  ## raw stdout. Blocking — only call through `runOffload`.
  if fakeDir.len > 0:
    let path = fakeDir / (kind & ".out")
    if not fileExists(path):
      raise newException(IOError, "fake SMI fixture missing: " & path)
    return readFile(path)
  let (exe, args) = SmiCmds[kind]
  let cmd =
    if timeoutExe.len > 0: (timeoutExe, @[$SmiTimeoutSecs, exe] & args)
    else: (exe, args)
  let p = startProcess(command = cmd[0], args = cmd[1],
    options = {poStdErrToStdOut, poUsePath})
  let raw = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  let outp = raw.strip()
  if code != 0:
    raise newException(IOError, exe & " exit " & $code & ": " &
      outp[0 ..< min(outp.len, 160)])
  if outp.len == 0:
    raise newException(IOError, exe & " produced no output")
  result = outp

proc httpGetBlocking*(url: string): string =
  ## Blocking GET used for the optional engine endpoints. Offload-pool only.
  let client = newHttpClient(timeout = HttpTimeoutMs)
  result = client.getContent(url)

# ---------- JSON walk helpers (port of JS num()/dig()) ----------

proc digJ(n: JsonNode, path: string): JsonNode =
  var cur = n
  for part in path.split('.'):
    if cur == nil or cur.kind != JObject or not cur.hasKey(part):
      return nil
    cur = cur[part]
  cur

proc jsonNum(n: JsonNode): OptF =
  ## Coerces a JSON node to a number like the JS `num()`: objects unwrap
  ## `.value`, strings are stripped to numeric chars, garbage becomes absent.
  if n == nil: return (false, 0.0)
  case n.kind
  of JInt: (true, float(n.getInt))
  of JFloat:
    if n.fnum.classify() == fcNaN: (false, 0.0) else: (true, n.fnum)
  of JString:
    var s = ""
    for c in n.str:
      if c in {'0'..'9', '.', '-'}: s.add c
    if s.len == 0: return (false, 0.0)
    try: (true, parseFloat(s)) except ValueError: (false, 0.0)
  of JObject:
    if n.hasKey("value"): jsonNum(n["value"]) else: (false, 0.0)
  else: (false, 0.0)

proc numAt(n: JsonNode, path: string): OptF =
  jsonNum(n.digJ(path))

proc parseColNum(s: string): OptF =
  let t = s.strip
  if t.len == 0: return (false, 0.0)
  try: (true, parseFloat(t)) except ValueError: (false, 0.0)

proc putOpt(o: JsonNode, key: string, v: OptF) =
  o[key] = if v[0]: %v[1] else: newJNull()

proc numOr(v: OptF, def: float): float =
  if v[0]: v[1] else: def

# ---------- vendor parsing ----------

proc gpuIndexOf(n: JsonNode): OptF =
  ## `gpu` field when present as int, else absent.
  if n != nil and n.hasKey("gpu") and n["gpu"].kind == JInt:
    (true, float(n["gpu"].getInt))
  else: (false, 0.0)

proc emptyGpuRow(index: OptF, vendor, name: string): JsonNode =
  result = newJObject()
  result["index"] = if index[0]: %(index[1].int) else: newJNull()
  result["vendor"] = %vendor
  result["name"] = %name
  for k in ["temp_c", "util_pct", "mem_used_mib", "mem_total_mib", "power_w",
            "power_limit_w", "sclk_mhz", "mclk_mhz", "temp_junction_c"]:
    result[k] = newJNull()

proc collectAmdGpus*(metricRaw, staticRaw: string): (JsonNode, OptS) =
  ## Maps amd-smi metric+static JSON into the dashboard GPU row shape.
  ## Returns (rows, optional error message).
  if metricRaw.len == 0: return (newJArray(), (false, ""))
  var metricData: JsonNode
  try: metricData = parseJson(metricRaw)
  except JsonParsingError as e:
    return (newJArray(), (true, "amd-smi: metric JSON: " & e.msg))
  var gpuData: JsonNode = nil
  if metricData.hasKey("gpu_data") and metricData["gpu_data"].kind == JArray:
    gpuData = metricData["gpu_data"]
  if gpuData == nil:
    return (newJArray(), (true, "amd-smi: no gpu_data in metric output"))
  var st: seq[JsonNode] = @[]
  if staticRaw.len > 0:
    try:
      let sd = parseJson(staticRaw)
      if sd.hasKey("gpu_data") and sd["gpu_data"].kind == JArray:
        for e in sd["gpu_data"]: st.add e
    except JsonParsingError: discard
  var rows = newJArray()
  for i in 0 ..< gpuData.len:
    let g = gpuData[i]
    let gIdx = g.gpuIndexOf
    var s: JsonNode = nil
    for cand in st:
      let cIdx = cand.gpuIndexOf
      if (gIdx[0] and cIdx[0] and gIdx[1] == cIdx[1]) or
          (not gIdx[0] and not cIdx[0]):
        s = cand
        break
    if s == nil and i < st.len: s = st[i]
    let nameNode = if s != nil: s.digJ("asic.market_name") else: nil
    let name =
      if nameNode != nil and nameNode.kind == JString and nameNode.str.len > 0:
        nameNode.str
      else: "AMD GPU"
    var row = emptyGpuRow(gIdx, "amd", name)
    let tempEdge = g.numAt("temperature.edge")
    let tempHot = g.numAt("temperature.hotspot")
    row.putOpt("temp_c", (if tempEdge[0]: tempEdge else: tempHot))
    row.putOpt("temp_junction_c", (if tempHot[0]: tempHot else: tempEdge))
    row.putOpt("util_pct", g.numAt("usage.gfx_activity"))
    row.putOpt("mem_used_mib", g.numAt("mem_usage.used_vram"))
    row.putOpt("mem_total_mib", g.numAt("mem_usage.total_vram"))
    row.putOpt("power_w", g.numAt("power.socket_power"))
    let stLimit = if s != nil: s.numAt("limit.ppt0.socket_power_limit") else: (false, 0.0)
    row.putOpt("power_limit_w",
      (if stLimit[0]: stLimit else: g.numAt("power.power_limit")))
    let sclk = g.numAt("clock.gfx_0.clk")
    row.putOpt("sclk_mhz", (if sclk[0]: sclk else: g.numAt("clock.gfx.clk")))
    let mclk = g.numAt("clock.mem_0.clk")
    row.putOpt("mclk_mhz", (if mclk[0]: mclk else: g.numAt("clock.mem.clk")))
    rows.add row
  (rows, (false, ""))

proc collectNvGpus*(csvRaw: string): (JsonNode, OptS) =
  ## Maps nvidia-smi CSV (nounits) into the dashboard GPU row shape.
  if csvRaw.len == 0: return (newJArray(), (false, ""))
  var rows = newJArray()
  for line in csvRaw.split('\n'):
    if line.strip.len == 0: continue
    let c = line.split(',').mapIt(it.strip)
    if c.len < 10: continue
    let name = if c[1].len > 0: c[1] else: "NVIDIA GPU"
    var row = emptyGpuRow(parseColNum(c[0]), "nvidia", name)
    let temp = parseColNum(c[2])
    row.putOpt("temp_c", temp)
    row.putOpt("temp_junction_c", temp)
    row.putOpt("util_pct", parseColNum(c[3]))
    row.putOpt("mem_used_mib", parseColNum(c[4]))
    row.putOpt("mem_total_mib", parseColNum(c[5]))
    row.putOpt("power_w", parseColNum(c[6]))
    row.putOpt("power_limit_w", parseColNum(c[7]))
    row.putOpt("sclk_mhz", parseColNum(c[8]))
    row.putOpt("mclk_mhz", parseColNum(c[9]))
    rows.add row
  (rows, (false, ""))

# ---------- engine (llama.cpp) metrics — optional, backend-side only ----------

const EngineAliases = {
  "prompt_tokens": @["prompt_tokens_total", "n_prompt_total"],
  "decode_tokens": @["decode_tokens_total", "n_decode_total"],
  "prompt_seconds": @["prompt_seconds_total"],
  "decode_seconds": @["decode_seconds_total", "tokens_predicted_seconds_total"],
  "tokens_predicted": @["tokens_predicted_total", "tokens_predicted_seconds_total"],
  "kv_used": @["kv_cache_used_tokens", "n_kv"],
  "kv_capacity": @["kv_cache_capacity_tokens", "n_cache", "n_tokens_max"],
  "kv_unchecked": @["kv_cache_unchecked_tokens", "n_kv_unchecked"],
  "processing": @["requests_processing"],
  "deferred": @["requests_deferred"],
}.toTable

proc aliasGet(vals: Table[string, float], metric: string): OptF =
  for n in EngineAliases[metric]:
    if vals.hasKey(n): return (true, vals[n])
  (false, 0.0)

proc parsePromText(text: string): Table[string, float] =
  ## Minimal Prometheus text exposition parser (port of parsePromText()).
  result = initTable[string, float]()
  for line in text.split('\n'):
    let ln = line.strip
    if ln.len == 0 or ln.startsWith("#"): continue
    let sp = ln.rsplit(maxsplit = 1)
    if sp.len != 2: continue
    var name = sp[0].strip
    let valStr = sp[1].strip
    if name.startsWith("llamacpp:"): name = name[9 .. ^1]
    let braceAt = name.find('{')
    if braceAt >= 0: name = name[0 ..< braceAt]
    name = name.strip
    if name.len == 0: continue
    if name.endsWith("_bucket") or name.endsWith("_sum") or name.endsWith("_count"):
      continue
    if result.hasKey(name): continue
    try:
      let v = parseFloat(valStr)
      if v.classify() != fcNaN: result[name] = v
    except ValueError: discard

type PrevSample = object
  has: bool
  t: float
  decodeTokens, promptTokens, tokensPredicted, decodeSeconds, promptSeconds: OptF

var gPrev: PrevSample
var gPropsAtMs* = 0.0
var gPropsModel = ""

proc engineRates(g: Table[string, float], tNow: float): (OptF, OptF) =
  ## (decode tok/s, prefill tok/s) from counter deltas (port of engineRates()).
  var tgS: OptF = (false, 0.0)
  var ppS: OptF = (false, 0.0)
  let dDec = g.aliasGet("decode_tokens")
  let dProm = g.aliasGet("prompt_tokens")
  let dPred = g.aliasGet("tokens_predicted")
  let dDecS = g.aliasGet("decode_seconds")
  let dPromS = g.aliasGet("prompt_seconds")
  if gPrev.has and dDec[0] and gPrev.decodeTokens[0]:
    let dtw = (tNow - gPrev.t) / 1000.0
    let diffDec = dDec[1] - gPrev.decodeTokens[1]
    let dPredDiff =
      if dPred[0] and gPrev.tokensPredicted[0]: dPred[1] - gPrev.tokensPredicted[1]
      else: diffDec
    let dDecSDiff =
      if dDecS[0] and gPrev.decodeSeconds[0]: OptF((true, dDecS[1] - gPrev.decodeSeconds[1]))
      else: (false, 0.0)
    if diffDec >= 0 and dtw > 0.2:
      tgS = if dDecSDiff[0] and dDecSDiff[1] > 0.01: (true, dPredDiff / dDecSDiff[1])
            elif dPredDiff > 0: (true, dPredDiff / dtw)
            else: (true, 0.0)
    if dProm[0] and gPrev.promptTokens[0]:
      let diffProm = dProm[1] - gPrev.promptTokens[1]
      if diffProm >= 0:
        let dPromSDiff =
          if dPromS[0] and gPrev.promptSeconds[0]: OptF((true, dPromS[1] - gPrev.promptSeconds[1]))
          else: (false, 0.0)
        ppS = if dPromSDiff[0] and dPromSDiff[1] > 0.01: (true, diffProm / dPromSDiff[1])
              elif diffProm > 0: (true, diffProm / dtw)
              else: (true, 0.0)
  gPrev = PrevSample(
    has: true, t: tNow, decodeTokens: dDec, promptTokens: dProm,
    tokensPredicted: dPred, decodeSeconds: dDecS, promptSeconds: dPromS)
  (tgS, ppS)

proc buildEngineObj*(metricsBody: string, propsBody: OptS): JsonNode =
  ## Returns the `engine` section for one snapshot. `propsBody` present means a
  ## fresh /props response arrived this tick (model name cached between ticks).
  let trimmed = metricsBody.strip
  if trimmed.startsWith("{"):
    # JSON engine (custom monitor) — pass through with a kind tag
    try:
      var obj = parseJson(trimmed)
      if obj.kind == JObject:
        obj["kind"] = %("json")
        return obj
    except JsonParsingError: discard
    return nil
  let vals = parsePromText(trimmed)
  let (tgS, ppS) = engineRates(vals, epochTime() * 1000.0)
  if propsBody[0]:
    gPropsAtMs = epochTime() * 1000.0
    try:
      let j = parseJson(propsBody[1])
      var model = ""
      if j.hasKey("alias") and j["alias"].kind == JString:
        model = j["alias"].str
      elif j.hasKey("model_path") and j["model_path"].kind == JString:
        let parts = j["model_path"].str.split('/')
        if parts.len > 0: model = parts[^1]
      gPropsModel = model
    except JsonParsingError:
      gPropsModel = ""
  let kvCap = vals.aliasGet("kv_capacity")
  let kvUsed = vals.aliasGet("kv_used")
  let kvUnchecked = vals.aliasGet("kv_unchecked")
  let processing = vals.aliasGet("processing")
  let deferred = vals.aliasGet("deferred")
  let pTokens = vals.aliasGet("prompt_tokens")
  let dTokens = vals.aliasGet("decode_tokens")
  result = newJObject()
  result["kind"] = %("llamacpp")
  var eng = newJObject()
  eng["model"] = %(if gPropsModel.len > 0: gPropsModel else: "llama-server")
  eng["max_context"] = if kvCap[0]: %(kvCap[1].int) else: newJNull()
  result["engine"] = eng
  var live = newJObject()
  live["state"] = %(if processing[0] and processing[1] > 0: "busy" else: "idle")
  live["queued"] = %(numOr(deferred, 0).int)
  live.putOpt("tok_s", tgS)
  live.putOpt("prefill_tok_s", ppS)
  result["live"] = live
  var totals = newJObject()
  totals.putOpt("prompt_tokens", pTokens)
  totals.putOpt("decode_tokens", dTokens)
  result["totals"] = totals
  var kv = newJObject()
  kv["used"] = %(numOr(kvUsed, 0))
  kv["capacity"] = if kvCap[0]: %kvCap[1] else: newJNull()
  kv["unchecked"] = %(numOr(kvUnchecked, 0))
  result["kv"] = kv
