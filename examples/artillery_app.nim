# artillery_app.nim
#
# ## 2D Turn-Based Artillery Duel (Pocket Tanks inspired)
# ##
# ## - Fully server-authoritative: all physics, scoring, weapons, AI and
# ##   match state live in this Nim backend
# ## - Two WebSocket players per match (create/join by code) or 1v1 vs AI
# ##   (Easy / Medium / Hard, server-side ballistic search)
# ## - Destructible heightmap terrain, wind, fuel-limited movement,
# ##   6 weapons across 4 families, proximity scoring + knockdowns +
# ##   toxin ticks, 10 rounds per player, no-death invariant
# ##
# ## Run:  ./examples/bin/artillery_app   (PORT env overrides, default 3005)
# ## Spec: examples/artillery/SPEC.md
##
import std/[json, math, tables, sequtils, strutils, random, os, times]

import ../nim_express/src/nim_express

# ---- shared constants (client mirrors these for the aim guide only) ----
const
  Cols = 320
  Rows = 180
  Cell = 4
  WorldW = 1280.0
  WorldH = 720.0
  Grav = 250.0
  WindAcc = 6.0
  MaxV = 560.0
  MaxFuel = 6
  MoveStep = 20.0
  Rounds = 10
  PrepTime = 90.0
  DraftTime = 20.0
  SimCap = 12.0

type
  WKind = enum wkBoom, wkDirt, wkMirv, wkToxin, wkTriple
  WeaponDef = object
    name, fam: string
    r, base, kb: float
    kind: WKind
  Tank = object
    x, y, vx, vy, angle, power, minY: float
    fuel: int
    air: bool
  Proj = object
    x, y, vx, vy: float
    w: int
    split: bool
  Phase = enum phWait, phDraft, phPrep, phSim, phOver
  Match = ref object
    id: string
    phase: Phase
    turn, cur: int
    wind: int
    timer: float
    windF: float
    winner: int
    tmh: seq[int]
    tmDirty: bool
    tanks: array[2, Tank]
    inv: array[2, seq[int]]
    sel: array[2, int]
    score: array[2, int]
    pool: seq[int]
    nextPicker: int
    projs: seq[Proj]
    toxin: array[2, seq[int]]
    toxinN: array[2, int]
    toxinAcc: array[2, float]
    toxinDone: array[2, int]
    lastBlaster: int
    simTime: float
    evs: seq[string]
    tickN: int
    ai: array[2, bool]
    diff: int
    aiAct: float
    aiStage: int
    sockets: array[2, WebSocket]

const Weaps: array[6, WeaponDef] = [
  WeaponDef(name: "Howitzer",  fam: "direct",  r: 52.0, base: 100.0, kb: 520.0, kind: wkBoom),
  WeaponDef(name: "Nuke",      fam: "direct",  r: 88.0, base: 45.0,  kb: 900.0, kind: wkBoom),
  WeaponDef(name: "Dirt Wall", fam: "builder", r: 40.0, base: 0.0,   kb: 0.0,   kind: wkDirt),
  WeaponDef(name: "MIRV",      fam: "cluster", r: 34.0, base: 60.0,  kb: 300.0, kind: wkMirv),
  WeaponDef(name: "Toxin",     fam: "toxin",   r: 0.0,  base: 0.0,   kb: 0.0,   kind: wkToxin),
  WeaponDef(name: "Triple",    fam: "cluster", r: 36.0, base: 40.0,  kb: 280.0, kind: wkTriple)]

var matches = initTable[string, Match]()

# ---- small helpers --------------------------------------------------------
proc groundY(m: Match, x: float): float =
  let c = clamp(int(x / Cell), 0, Cols - 1)
  float((Rows - m.tmh[c]) * Cell)

proc newId(): string =
  const abc = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  for _ in 0 ..< 6:
    result.add(abc[rand(0 .. abc.high)])

proc ev(m: Match, k: string, x, y: float, extra = "") =
  var s = "{\"t\":\"ev\",\"k\":\"" & k & "\",\"x\":" & $(round(x).int)
  s &= ",\"y\":" & $(round(y).int)
  if extra.len > 0: s &= "," & extra
  s.add("}")
  m.evs.add(s)

# ---- terrain --------------------------------------------------------------
proc genTerrain(m: Match) =
  let s1 = rand(0.0..6.28)
  let s2 = rand(0.0..6.28)
  let s3 = rand(0.0..6.28)
  var walk = 0.0
  for c in 0 ..< Cols:
    let u = float(c) / float(Cols)
    walk += (rand(-1.0..1.0)) * 0.35
    walk *= 0.985
    var h = 0.42 * float(Rows) +
      0.10 * float(Rows) * sin(u * 6.28 * 1.3 + s1) +
      0.07 * float(Rows) * sin(u * 6.28 * 3.1 + s2) +
      0.05 * float(Rows) * sin(u * 6.28 * 7.7 + s3) +
      walk * 4.0
    if u > 0.18 and u < 0.30:
      h += (1.0 - abs(u - 0.24) / 0.06) * 14.0
    if u > 0.70 and u < 0.82:
      h += (1.0 - abs(u - 0.76) / 0.06) * 14.0
    m.tmh.add(clamp(int(h), 18, 150))
  # flat pads under the tanks
  for c in 24 .. 40: m.tmh[c] = m.tmh[32]
  for c in 280 .. 296: m.tmh[c] = m.tmh[288]

proc blast(m: Match, px, py, r: float, wIdx, shooter: int) =
  # carve crater (unsupported material collapses)
  let c0 = max(0, int((px - r) / Cell) - 1)
  let c1 = min(Cols - 1, int((px + r) / Cell) + 1)
  for c in c0 .. c1:
    let dx = (float(c) + 0.5) * 4.0 - px
    if abs(dx) <= r:
      let dy = sqrt(max(0.0, r * r - dx * dx))
      let surf = float((Rows - m.tmh[c]) * Cell)
      if py - dy <= surf:
        let rowB = clamp(int((py + dy) / Cell), 0, Rows - 1)
        let nh = Rows - (rowB + 1)
        if nh < m.tmh[c]:
          m.tmh[c] = nh
          m.tmDirty = true
  # scoring + knockback on tanks
  let w = Weaps[wIdx]
  for o in 0 .. 1:
    let t = m.tanks[o]
    let dx = t.x - px
    let dy = (t.y - 12) - py
    let d = sqrt(dx * dx + dy * dy)
    if w.kind == wkBoom or w.kind == wkMirv or w.kind == wkTriple:
      let hit = d < r + 20
      let near = d < r + 40
      if (o == shooter and hit) or (o != shooter and near):
        let pts = int(round(w.base * max(0.0, 1.0 - d / (r + 40))))
        if pts > 0:
          if o == shooter:
            m.score[shooter] -= pts
            m.ev("score", t.x, t.y - 30, "\"s\":\"-" & $pts & "\"")
          else:
            m.score[shooter] += pts
            m.ev("score", t.x, t.y - 30, "\"s\":\"+" & $pts & "\"")
    if d < r * 1.8 and w.kb > 0:
      let f = 1.0 - d / (r * 1.8)
      let ang = arctan2(t.y - 12 - py, t.x - px)
      m.tanks[o].vx += cos(ang) * w.kb * f
      m.tanks[o].vy -= (sin(ang) * w.kb * f * 0.5 + 180.0 * f)
      m.tanks[o].air = true

proc deposit(m: Match, px, py, r: float) =
  let c0 = max(0, int((px - r) / Cell) - 1)
  let c1 = min(Cols - 1, int((px + r) / Cell) + 1)
  for c in c0 .. c1:
    let dx = (float(c) + 0.5) * 4.0 - px
    if abs(dx) <= r:
      let dy = sqrt(max(0.0, r * r - dx * dx))
      let rowT = clamp(int((py - dy) / 4.0), 0, Rows - 1)
      let target = Rows - rowT
      if target > m.tmh[c]:
        m.tmh[c] = min(target, 155)
        m.tmDirty = true

proc toxinDrop(m: Match, px, py: float, shooter: int) =
  let cc = clamp(int(px / Cell), 0, Cols - 1)
  for dc in -5 .. 5:
    let c = cc + dc
    if c >= 0 and c < Cols:
      let n = 1 + (5 - abs(dc)) div 2
      m.toxin[shooter][c] += n
      m.toxinN[shooter] += n
  m.ev("toxin", px, py, "\"s\":\"26\"")

# ---- physics ---------------------------------------------------------------
proc stepTank(m: Match, i: int, dt: float) =
  var t = m.tanks[i]
  t.vy += Grav * dt
  t.x += t.vx * dt
  t.y += t.vy * dt
  if t.x < 16:
    t.x = 16
    t.vx = 0
  if t.x > WorldW - 16:
    t.x = WorldW - 16
    t.vx = 0
  let ground = groundY(m, t.x)
  if t.y >= ground:
    if t.vy > 140 and (ground - t.minY) >= 50 and m.lastBlaster >= 0 and m.lastBlaster != i:
      m.score[m.lastBlaster] += 35
      m.ev("score", t.x, t.y - 30, "\"s\":\"+35 kd\"")
    t.y = ground
    t.vy = 0
    t.vx *= 0.90
    t.minY = ground
    t.air = false
  else:
    t.minY = min(t.minY, t.y)
    t.air = true
  m.tanks[i] = t

proc tankSettled(m: Match, i: int): bool =
  let t = m.tanks[i]
  not t.air and abs(t.vx) < 3

proc stepProj(m: Match, i: int, dt: float) =
  var p = m.projs[i]
  p.vx += m.windF * WindAcc * dt
  p.vy += Grav * dt
  p.x += p.vx * dt
  p.y += p.vy * dt
  # MIRV splits at apex
  if p.split and p.vy >= 30.0 and m.projs.len < 24:
    let ox = p.x
    let oy = p.y
    m.ev("split", ox, oy)
    for k in [-1, 0, 1]:
      m.projs.add(Proj(x: ox, y: oy, vx: p.vx + 110.0 * float(k),
                     vy: -40.0 + 30.0 * float(k), w: p.w, split: false))
    m.projs.delete(i)
    return
  if p.x < -20 or p.x > WorldW + 20:
    m.projs.delete(i)
    return
  let c = clamp(int(p.x / Cell), 0, Cols - 1)
  if p.y >= float((Rows - m.tmh[c]) * Cell):
    let px = p.x
    let py = p.y
    let w = Weaps[p.w]
    case w.kind
    of wkBoom, wkMirv, wkTriple:
      blast(m, px, py, w.r, p.w, m.lastBlaster)
      m.ev("boom", px, py, "\"r\":" & $(int(w.r)))
    of wkDirt:
      deposit(m, px, py, w.r)
      m.ev("dirt", px, py, "\"r\":" & $(int(w.r)))
    of wkToxin:
      toxinDrop(m, px, py, m.lastBlaster)
    m.projs.delete(i)
  else:
    m.projs[i] = p

proc stepToxin(m: Match, dt: float) =
  for s in 0 .. 1:
    if m.toxinN[s] <= 0:
      continue
    var pool = m.toxin[s]
    # flow: move 1 cell toward the lower free surface
    for c in 0 ..< Cols:
      let n = pool[c]
      if n <= 0: continue
      let free = float(Rows - m.tmh[c]) + 4.0 * float(n)
      if c < Cols - 1:
        let fr = float(Rows - m.tmh[c + 1]) + 4.0 * float(pool[c + 1])
        if fr < free - 1:
          pool[c] -= 1
          pool[c + 1] += 1
          continue
      if c > 0:
        let fl = float(Rows - m.tmh[c - 1]) + 4.0 * float(pool[c - 1])
        if fl < free - 1:
          pool[c] -= 1
          pool[c - 1] += 1
    m.toxin[s] = pool
    # decay: 1 cell every 16 ticks
    if (m.tickN + s * 8) mod 16 == 0 and m.toxinN[s] > 0:
      var c = (int(m.tickN) div 16 + s * 97) mod Cols
      for _ in 0 ..< Cols:
        if pool[c] > 0:
          pool[c] -= 1
          m.toxinN[s] -= 1
          m.toxin[s] = pool
          break
        c = (c + 1) mod Cols
    # damage ticks on tanks
    for o in 0 .. 1:
      let tc = clamp(int(m.tanks[o].x / Cell), 0, Cols - 1)
      if pool[tc] > 0 and m.toxinDone[s] < 300:
        let surf = float((Rows - m.tmh[tc]) * Cell)
        if m.tanks[o].y - surf < 4.0 * float(pool[tc]) + 8.0:
          m.toxinAcc[s] += dt
          while m.toxinAcc[s] >= 0.6:
            m.toxinAcc[s] -= 0.6
            m.score[s] += 10
            m.score[o] -= 10
            m.toxinDone[s] += 10
            let sgn = if o == s: "-" else: "+"
            m.ev("score", m.tanks[o].x, m.tanks[o].y - 30,
                 "\"s\":\"" & sgn & "10 toxic\"")

# ---- turn flow ---------------------------------------------------------------
proc sendState(m: Match, full: bool)
proc broadcastState(m: Match)
proc broadcastFull(m: Match)
proc aiPickWeapon(m: Match, p: int): int

proc fire(m: Match, p: int) =
  if m.projs.len >= 40: return
  m.phase = phSim
  m.simTime = 0.0
  m.lastBlaster = p
  m.toxinAcc = [0.0, 0.0]
  let t = m.tanks[p]
  let a = t.angle * Pi / 180.0
  let v = t.power / 100.0 * MaxV
  let mx = t.x + cos(a) * 24
  let my = (t.y - 12) - sin(a) * 24
  let w = m.inv[p][m.sel[p]]
  case Weaps[w].kind
  of wkTriple:
    for i, pw in [0.85, 1.0, 1.15]:
      let aa = a + 0.07 * float(i)
      m.projs.add(Proj(x: mx, y: my, vx: cos(aa) * v * pw, vy: -sin(aa) * v * pw,
                       w: w, split: false))
  of wkMirv:
    m.projs.add(Proj(x: mx, y: my, vx: cos(a) * v, vy: -sin(a) * v, w: w, split: true))
  else:
    m.projs.add(Proj(x: mx, y: my, vx: cos(a) * v, vy: -sin(a) * v, w: w, split: false))
  m.ev("launch", mx, my, "\"s\":\"" & Weaps[w].name & "\"")

proc resolve(m: Match) =
  m.turn += 1
  if m.turn >= Rounds * 2:
    m.phase = phOver
    if m.score[0] > m.score[1]: m.winner = 0
    elif m.score[1] > m.score[0]: m.winner = 1
    else: m.winner = 2
    let res = %*{"t": "result", "winner": m.winner,
                 "score": [m.score[0], m.score[1]]}
    for s in m.sockets:
      if s != nil: s.sendText($res)
    return
  m.cur = m.turn mod 2
  if m.cur == 0:
    m.wind = if m.turn <= 2: rand(-3..3) else: rand(-10..10)
    m.windF = float(m.wind)
  m.timer = PrepTime
  if m.ai[m.cur]:
    m.aiStage = 0
    m.aiAct = 1.2
  m.phase = phPrep

proc simDone(m: Match): bool =
  m.projs.len == 0 and tankSettled(m, 0) and tankSettled(m, 1) and
    m.toxinN[0] == 0 and m.toxinN[1] == 0

proc startDraft(m: Match) =
  var pool: seq[int] = @[]
  for i in 0 ..< 2:
    for w in 0 ..< 6:
      pool.add(w)
  pool.shuffle()
  m.pool = pool
  m.nextPicker = 0
  m.phase = phDraft
  m.timer = DraftTime
  if m.ai[0]:
    m.aiStage = 0
    m.aiAct = 1.5

proc doPick(m: Match, p: int, idx: int) =
  let i = m.pool.findIt(it == idx)
  if i < 0: return
  m.pool.delete(i)
  m.inv[p].add(idx)
  m.nextPicker = 1 - p
  m.timer = DraftTime
  if m.inv[0].len >= 3 and m.inv[1].len >= 3:
    m.phase = phPrep
    m.turn = 0
    m.cur = 0
    m.timer = PrepTime
    m.wind = rand(-3..3)
    m.windF = float(m.wind)
    if m.ai[0]:
      m.aiStage = 0
      m.aiAct = 1.2
  broadcastState(m)

proc aiPickWeapon(m: Match, p: int): int =
  if m.diff == 1 or m.pool.len == 0:
    return m.pool[rand(0 .. m.pool.high)]
  # prefer high base value, slight randomness
  var best = m.pool[0]
  var bestV = -1.0
  for w in m.pool:
    let v = Weaps[w].base + rand(0.0..40.0)
    if v > bestV:
      bestV = v
      best = w
  best

# ---- AI ------------------------------------------------------------------------
proc simTrajectory(m: Match, x0, y0, vx0, vy0: float): (float, float) =
  var x = x0
  var y = y0
  var vx = vx0
  var vy = vy0
  const dt = 1.0 / 30.0
  for _ in 0 ..< 700:
    vx += m.windF * WindAcc * dt
    vy += Grav * dt
    x += vx * dt
    y += vy * dt
    if x < 0 or x > WorldW:
      break
    let c = clamp(int(x / Cell), 0, Cols - 1)
    if y >= float((Rows - m.tmh[c]) * Cell):
      return (x, y)
  (x, y)

proc aiChooseShot(m: Match, p: int): (float, float, int) =
  let foe = 1 - p
  let tx = m.tanks[foe].x
  let ty = m.tanks[foe].y - 12
  let t = m.tanks[p]
  let steps = if m.diff == 1: (12, 15)
              elif m.diff == 2: (6, 10)
              else: (3, 4)
  let noise = if m.diff == 1: 30.0 elif m.diff == 2: 12.0 else: 3.0
  var bestA = 90.0
  var bestP = 60.0
  var bestW = m.sel[p]
  var bestS = -1e18
  for si in 0 .. 2:
    let wIdx = m.inv[p][si]
    let w = Weaps[wIdx]
    if w.kind == wkToxin:
      continue
    var aDeg = 15.0
    while aDeg <= 165.0:
      let a = aDeg * Pi / 180.0
      let ca = cos(a)
      let sa = sin(a)
      let mx = t.x + ca * 24
      let my = (t.y - 12) - sa * 24
      var pw = 20.0
      while pw <= 100.0:
        let v = pw / 100.0 * MaxV
        let (ix, iy) = simTrajectory(m, mx, my, ca * v, -sa * v)
        let d = sqrt((ix - tx) * (ix - tx) + (iy - ty) * (iy - ty))
        var s: float
        if w.kind == wkDirt:
          s = 5.0
        else:
          s = w.base * max(0.0, 1.0 - d / (w.r + 40.0))
        s -= rand(0.0..1.0) * noise
        if s > bestS:
          bestS = s
          bestA = aDeg
          bestP = pw
          bestW = si
        pw += float(steps[1])
      aDeg += float(steps[0])
  (bestA, bestP, bestW)

# ---- snapshots ------------------------------------------------------------------
proc phaseStr(p: Phase): string =
  case p
  of phWait: "wait"
  of phDraft: "draft"
  of phPrep: "prep"
  of phSim: "sim"
  of phOver: "over"

proc sendState(m: Match, full: bool) =
  # projectiles
  var pr = newJArray()
  for p in m.projs:
    pr.add(%[int(round(p.x)), int(round(p.y))])
  # toxin columns (any pool nonzero)
  var tx = newJArray()
  for c in 0 ..< Cols:
    if m.toxin[0][c] > 0 or m.toxin[1][c] > 0:
      tx.add(%[c, m.toxin[0][c], m.toxin[1][c]])
  var tk = newJArray()
  for i in 0 .. 1:
    let t = m.tanks[i]
    tk.add(%[int(round(t.x)), int(round(t.y)), int(round(t.angle)),
             int(round(t.power)), t.fuel])
  var j = %*{
    "t": "state", "ph": phaseStr(m.phase), "turn": m.turn, "cur": m.cur,
    "rnd": min(Rounds, m.turn div 2 + 1), "wind": m.wind,
    "timer": int(round(m.timer)),
    "winner": m.winner,
    "sc": [m.score[0], m.score[1]],
    "tk": tk, "inv": [m.inv[0], m.inv[1]], "sel": [m.sel[0], m.sel[1]],
    "pr": pr, "tx": tx, "pool": m.pool, "nxt": m.nextPicker,
    "ai": [m.ai[0], m.ai[1]], "diff": m.diff
  }
  if full or m.tmDirty:
    j["tm"] = %m.tmh
    m.tmDirty = false
  let msg = $j
  for s in m.sockets:
    if s != nil:
      for e in m.evs:
        s.sendText(e)
      s.sendText(msg)
  m.evs.setLen(0)

proc broadcastState(m: Match) =
  sendState(m, full = false)

proc broadcastFull(m: Match) =
  sendState(m, full = true)

# ---- match creation ---------------------------------------------------------------
proc newMatch(id: string, hasAi: bool, diff: int): Match =
  result = Match(id: id, phase: phWait, winner: -1, lastBlaster: -1,
                 tickN: 0, diff: diff)
  for s in 0 .. 1:
    result.toxin[s] = newSeq[int](Cols)
  genTerrain(result)
  for i in 0 .. 1:
    let x = if i == 0: 120.0 else: 1160.0
    result.tanks[i] = Tank(x: x, y: groundY(result, x), angle: 90.0,
                           power: 50.0, fuel: MaxFuel)
    result.tanks[i].minY = result.tanks[i].y
  result.ai[1] = hasAi
  result.ai[0] = false

proc playerOf(ws: WebSocket): (Match, int) =
  for m in matches.values:
    if m.sockets[0] == ws: return (m, 0)
    if m.sockets[1] == ws: return (m, 1)
  (nil, -1)

proc attach(m: Match, p: int, ws: WebSocket) =
  m.sockets[p] = ws
  ws.sendText($(%*{"t": "hello", "you": p}))
  if m.phase == phWait and
      (m.sockets[0] != nil or m.ai[0]) and
      (m.sockets[1] != nil or m.ai[1]):
    startDraft(m)
    broadcastFull(m)

# ---- per-match tick (25 ms, event loop thread) -------------------------------------
proc tickMatch(m: Match, dt: float) =
  m.tickN += 1
  case m.phase
  of phWait, phOver:
    return
  of phDraft:
    let p = m.nextPicker
    if m.ai[p]:
      m.aiAct -= dt
      if m.aiAct <= 0:
        doPick(m, p, aiPickWeapon(m, p))
        return
    m.timer -= dt
    if m.timer <= 0.0:
      doPick(m, p, m.pool[0])
      return
    if m.tickN mod 10 == 0:
      broadcastState(m)
  of phPrep:
    let p = m.cur
    if m.ai[p]:
      m.aiAct -= dt
      if m.aiAct <= 0 and m.aiStage == 0:
        let (a, pw, sel) = aiChooseShot(m, p)
        m.tanks[p].angle = a
        m.tanks[p].power = pw
        m.sel[p] = sel
        m.aiStage = 1
        m.aiAct = 0.8
        broadcastState(m)
      elif m.aiAct <= 0 and m.aiStage == 1:
        m.aiStage = 2
        fire(m, p)
        broadcastFull(m)
        return
    else:
      m.timer -= dt
      if m.timer <= 0.0:
        fire(m, p)
        broadcastFull(m)
        return
    if m.tickN mod 10 == 0:
      broadcastState(m)
  of phSim:
    m.simTime += dt
    for _ in 0 .. 2:
      let sdt = dt / 3.0
      for i in countdown(m.projs.len - 1, 0):
        stepProj(m, i, sdt)
      stepTank(m, 0, sdt)
      stepTank(m, 1, sdt)
      stepToxin(m, sdt)
    if simDone(m) or m.simTime >= SimCap:
      resolve(m)
      broadcastFull(m)
      return
    broadcastState(m)

proc gameTick() =
  for m in matches.values:
    tickMatch(m, 0.025)

# ---- commands ------------------------------------------------------------------------
proc lobbyFragment(inner: string): string =
  ## HTMX OOB fragment: replaces #lobby-body in the client DOM. The
  ## htmx ws extension swaps any element whose id matches one already
  ## present in the page.
  "<div id=\"lobby-body\">" & inner & "</div>"

proc matchCard(title: string, code: string, status: string): string =
  ## A match-code card inside the lobby: share link + status line.
  "<div class=\"got-card\">" &
  "<div class=\"got-title\">" & title & "</div>" &
  "<div class=\"got-code\">" & code & "</div>" &
  "<a class=\"got-link\" href=\"/?c=" & code & "\">" &
  "/?c=" & code & "</a>" &
  "<div class=\"got-status\">" & status & "</div>" &
  "</div>"


proc handleHtmxLobby(ws: WebSocket, msg: JsonNode) =
  ## HTMX ws-send lobby actions. The htmx ws extension serializes the
  ## clicked button / submitted form into a JSON object carrying a
  ## "HEADERS" key (and no "t" field): {} plus hx-vals for new matches,
  ## {"diff":N} for AI matches, {"code":"..."} for joins. The sending
  ## WebSocket becomes the creator (seat 0) or the joiner.
  let (om, op) = playerOf(ws)
  if om != nil:
    if om.phase notin {phOver}:
      return  # already in a live match; ignore lobby spam
    om.sockets[op] = nil  # leave the finished match cleanly
  if msg.hasKey("code"):
    let code = msg["code"].getStr().strip().toUpperAscii()
    let m = matches.getOrDefault(code)
    if m == nil or (m.sockets[0] != nil and m.sockets[1] != nil):
      ws.sendText(lobbyFragment(
        "<div class=\"got-error\">Match not found or already full.</div>"))
      return
    if m.sockets[0] == nil:
      attach(m, 0, ws)
    else:
      attach(m, 1, ws)
    ws.sendText(lobbyFragment(matchCard(
      "Joining match", code, "Connecting…")))
    broadcastFull(m)
  else:
    var hasAi = true
    var diff = 2
    if msg.hasKey("diff"):
      try:
        diff = parseInt(msg["diff"].getStr())
      except CatchableError:
        diff = 2
      diff = clamp(diff, 1, 3)
    else:
      hasAi = false
    let id = newId()
    let m = newMatch(id, hasAi, diff)
    matches[id] = m
    attach(m, 0, ws)
    if hasAi:
      ws.sendText(lobbyFragment(matchCard(
        "AI opponent ready", id, "Starting…")))
    else:
      ws.sendText(lobbyFragment(matchCard(
        "Match created", id,
        "Waiting for your opponent — share the code or link.")))

proc handleMsg(ws: WebSocket, raw: string) =
  var msg: JsonNode
  try:
    msg = parseJson(raw)
  except CatchableError:
    return
  # HTMX ws-send messages are JSON objects with a "HEADERS" key and no
  # "t" field; everything else in this game carries "t".
  if msg.kind == JObject and msg.hasKey("HEADERS") and not msg.hasKey("t"):
    handleHtmxLobby(ws, msg)
    return
  let t = msg["t"].getStr()
  if t == "new_ai":
    let (om, op) = playerOf(ws)
    if om != nil and om.phase notin {phOver}:
      return
    let diff = clamp(msg["diff"].getInt(2), 1, 3)
    let id = newId()
    let m = newMatch(id, true, diff)
    matches[id] = m
    attach(m, 0, ws)
    broadcastFull(m)
  elif t == "new":
    let (om, op) = playerOf(ws)
    if om != nil and om.phase notin {phOver}:
      return
    let id = newId()
    let m = newMatch(id, false, 2)
    matches[id] = m
    attach(m, 0, ws)
    let offer = %*{"t": "offer", "match": id}
    ws.sendText($offer)
    broadcastFull(m)
  elif t == "join":
    let code = msg["code"].getStr().strip().toUpperAscii()
    let m = matches.getOrDefault(code)
    if m == nil or (m.sockets[0] != nil and m.sockets[1] != nil):
      ws.sendText($(%*{"t": "error", "s": "match not found or full"}))
      return
    # Seat 0 belongs to the creator (who gets it from the HTMX lobby
    # over this same socket); opponents arriving from the share link
    # (?c=CODE, which sends this message on connect) take seat 1.
    if m.sockets[0] == nil:
      attach(m, 0, ws)
    else:
      attach(m, 1, ws)
    broadcastFull(m)
  elif t == "state":
    let (m, p) = playerOf(ws)
    if m != nil:
      broadcastFull(m)
    return
  else:
    let (m, p) = playerOf(ws)
    if m == nil or p < 0: return
    if t == "pick":
      if m.phase == phDraft and m.nextPicker == p and not m.ai[p]:
        doPick(m, p, msg["idx"].getInt(-1))
    elif t == "aim":
      if m.phase == phPrep and m.cur == p and not m.ai[p]:
        m.tanks[p].angle = clamp(msg["deg"].getFloat(90), 5.0, 175.0)
        broadcastState(m)
    elif t == "power":
      if m.phase == phPrep and m.cur == p and not m.ai[p]:
        m.tanks[p].power = clamp(msg["pct"].getFloat(50), 10.0, 100.0)
        broadcastState(m)
    elif t == "move":
      if m.phase == phPrep and m.cur == p and not m.ai[p] and
          m.tanks[p].fuel > 0:
        let d = msg["d"].getInt(0)
        if d != 0:
          m.tanks[p].x = clamp(m.tanks[p].x + MoveStep * float(d), 16.0,
                               WorldW - 16.0)
          m.tanks[p].y = groundY(m, m.tanks[p].x)
          m.tanks[p].minY = m.tanks[p].y
          m.tanks[p].vx = 0
          m.tanks[p].vy = 0
          m.tanks[p].fuel -= 1
          broadcastState(m)
    elif t == "sel":
      if m.phase == phPrep and m.cur == p and not m.ai[p]:
        let i = msg["idx"].getInt(0)
        if i >= 0 and i < 3:
          m.sel[p] = i
          broadcastState(m)
    elif t == "fire":
      if m.phase == phPrep and m.cur == p and not m.ai[p]:
        fire(m, p)
        broadcastFull(m)

proc onWsClose(ws: WebSocket) =
  let (m, p) = playerOf(ws)
  if m == nil: return
  m.sockets[p] = nil
  if m.phase notin {phWait, phOver}:
    m.ai[p] = true
    if m.diff == 0:
      m.diff = 2
    if (m.phase == phPrep and m.cur == p) or (m.phase == phDraft and m.nextPicker == p):
      m.aiStage = 0
      m.aiAct = 1.2
    echo "[artillery] player " & $p & " left match " & m.id & ", AI takes over"
    broadcastState(m)

# ---- app ---------------------------------------------------------------------------

proc findClientAssets(): string =
  ## Locate the artillery client assets directory (index.html, client.js)
  ## next to the binary or relative to the current working directory.
  var dirs: seq[string]
  when not defined(windows):
    try:
      if fileExists("/proc/self/exe"):
        let binDir = "/proc/self/exe".parentDir
        if binDir.endsWith("bin"):
          dirs.add(binDir.parentDir / "artillery")
    except OSError:
      discard
  dirs.add("artillery")
  dirs.add("examples" / "artillery")
  for d in dirs:
    if fileExists(d / "index.html"):
      return d
  echo "[artillery] WARNING: client assets not found; / will return 503"
  ""

proc createApp(): ExpressApp {.gcsafe.} =
  let app = newExpressApp()
  app.server.options.socketNoDelay = true
  app.server.options.socketKeepAlive = true
  app.server.options.wsKeepaliveInterval = 20_000
  # The default 60 s WS idle timeout is safe for this push-based game:
  # server->client sends (state broadcasts, keepalive pings every 20 s)
  # re-arm the idle deadline, so players can stay silent for whole prep
  # turns (up to PrepTime=90 s) without the socket being closed.

  let assets = findClientAssets()
  if assets.len == 0:
    echo "[artillery] WARNING: client assets not found; / will return 503"

  app.get("/") do (req: Request, res: Response):
    if assets.len == 0:
      res.status(503).send("client assets not found")
      return
    let html = readFile(assets / "index.html")
    res.contentType("text/html; charset=utf-8")
    res.send(html)

  # The uSockets sendfile fast path used by serveStatic can hang for
  # small JS files, so serve client.js through the regular write path.
  app.get("/client.js") do (req: Request, res: Response):
    if assets.len == 0:
      res.status(503).send("client assets not found")
      return
    let js = readFile(assets / "client.js")
    res.contentType("text/javascript; charset=utf-8")
    res.set("Cache-Control", "no-cache")
    res.send(js)

  app.get "/health", proc(req: Request, res: Response) =
    res.jsonRaw($(%*{"ok": true, "matches": matches.len}))

  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    handleMsg(ws, message)

  app.onWsClose proc(ws: WebSocket) =
    onWsClose(ws)

  app.setInterval(gameTick, 25)
  app

when isMainModule:
  # Seed the global RNG (Nim 2.2: no auto-seed) so match ids, wind and AI
  # vary between server runs. Microsecond clock is plenty for a game.
  randomize(int64(epochTime() * 1_000_000.0))
  let port =
    try: parseInt(getEnv("PORT", "3005"))
    except ValueError: 3005
  echo "[artillery] artillery duel listening on port " & $port
  createApp().run(port)
