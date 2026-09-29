# 2D Turn-Based Artillery Duel — Spec v2 (implemented)

Server-authoritative WebSocket artillery duel (Pocket Tanks inspired).
All game logic runs in the Nim backend (`examples/artillery_app.nim`);
the browser client is a dumb renderer + input sender.

Research inputs: Pocket Tanks (Blitwise 2001) — 10 volleys per player,
proximity scoring, fixed 4-move budget, weapon draft shop, destructible
terrain, wind (Wikipedia / GameFAQs / Fandom); modern open-source
artillery clones (per-column terrain, unsupported-material collapse,
crater settle, credit/fuel economies).

## 1. Core loop
- 10 rounds per player = 20 turns, alternating (P0 first).
- Turn lifecycle: **prep** (aim / power / move / weapon select, 90 s timer,
  auto-fires on expiry) → **sim** (server simulates flight, blasts,
  collapse, falls at 40 Hz and streams 40 Hz snapshots) → **resolve**
  (score events, wind may refresh at round boundary, turn passes).
- **No-death invariant**: tanks never die or leave the map. Scoring only.
- Victory: highest score after turn 20; tie = draw.
- Match length: 20 turns, each with a 90 s prep timer (auto-fires at zero).
  A full match is at most 30 minutes; against AI it typically finishes in
  well under 2 minutes (AI prep is a few seconds per turn).

## 2. World & physics (constants, shared with client for the aim guide)
- 320×180 cell grid, 4 px/cell → 1280×720 world.
- Gravity 250 px/s², max muzzle speed 560 px/s (power 100%).
- Wind: integer −10..10 per round (weak in first 2 rounds), horizontal
  acceleration 6 px/s² per unit. Shown as a persistent HUD arrow.
- Deterministic server simulation, fixed 25 ms tick with 3 physics substeps
  (no projectile tunneling through 4 px cells).

## 3. Terrain
- Heightmap `tmh[320]` (solid cells from the bottom). Generated per match:
  layered sine waves + low-freq noise + random bumps; tanks start at
  x=120 (Red) and x=1160 (Blue) on the surface.
- Explosions carve circular craters; material below a blast that would
  float is removed (unsupported material collapses).
- Terrain-builder weapons raise the surface inside their blast circle
  (mounds / bunkers), capped at 155 rows.
- Tanks settle to the surface; if the ground under a tank is hollowed out
  it falls (gravity), and a fall ≥ 50 px scores a **knockdown** bonus for
  the last blaster (unless self-caused).

## 4. Tanks & mobility
- Two identical tanks, Red vs Blue. No HP.
- Fuel: 6 steps per match, each step moves 20 px horizontally (clamped to
  map). Non-replenishing (mirrors Pocket Tanks' fixed 4-move budget).
- Aim: 5..175° (server clamps), power: 10..100%. Inputs lock on fire.

## 5. Weapons (six, four functional families)
Draft: pool of 12 (2 copies of each), alternating picks, 3 per player.

| # | Name     | Family        | Blast r | Base pts | Knockback | Notes |
|---|----------|---------------|---------|----------|-----------|-------|
| 0 | Howitzer | direct        | 52      | 100      | 520       | clean crater |
| 1 | Nuke     | direct        | 88      | 45       | 900       | big area, weak per-point, heavy launch |
| 2 | Dirt Wall| builder       | 40      | 0        | 0         | raises terrain inside circle (no damage, no self-harm) |
| 3 | MIRV     | cluster       | 34      | 60       | 300       | splits at apex into 3 warheads |
| 4 | Toxin    | toxin         | —       | 0        | 0         | 21-cell fluid pool (11 columns) on impact: flows downhill, pools in valleys |
| 5 | Triple   | cluster       | 36      | 40       | 280       | 3 shells spread in power (−15/0/+15%) plus a small angle fan |

## 6. Scoring engine
- Blast proximity: `pts = base * max(0, 1 − d/(r+40))` where d is distance
  blast-center → tank-center. Enemy tank: shooter +pts. Shooter's own tank
  (d < r+20): shooter −pts (self-harm). Both may apply for one blast.
- Knockdown: +35 to last blaster when a fall ≥ 50 px results from their shot.
- Toxin tick: every 0.6 s a pool standing under a tank ticks: +10 shooter /
  −10 owner, 300 pts total cap per shooter (toxin is a slow burn). Pools
  flow (1 cell toward the lower free surface per physics substep) and decay
  (1 cell every 16 ticks).
- All score changes emit floating "+N"/"−N" events at the impact site.

## 7. Modes
- **vs AI**: ballistic search over an angle×power grid with simulated
  terrain impact, scoring by expected proximity damage, plus random noise as
  the difficulty error: Easy 12°/15% steps (30% noise), Medium 6°/10% steps
  (12% noise), Hard 3°/4% steps (3% noise). Each search covers all 3
  non-toxin weapons in the AI's inventory and may switch weapons mid-turn;
  Hard also picks weapons strategically in the draft (incl. defensive dirt).
  Toxin is never fired by the AI (its tick damage is hard to aim).
- **2-player**: create match → 6-char code → second browser joins → draft.
- Robustness: a human disconnect mid-match is auto-replaced by Medium AI.

## 8. Networking
- One WS per browser; JSON messages; server routes by match code.
- **No HTTP API endpoints exist** — the lobby is driven over the same
  WebSocket. The page loads HTMX (1.9.10) with its `ws` extension:
  `<body hx-ws="connect:/ws">` and lobby controls use `hx-ws="send"`.
  The extension serializes the clicked button / submitted form into a
  JSON object (form fields + a `HEADERS` key, no `t` field) and sends it
  on the shared socket; the server answers with an HTML fragment whose
  `id`-tagged children are OOB-swapped into the page (the `#lobby-body`
  match-code card). The client overrides `htmx.createWebSocket` so htmx
  and the game logic share one connection; plain-JSON messages have no
  `id`-tagged children, so htmx ignores them and the game logic skips
  non-JSON messages. There is a CDN-less fallback that drives a plain
  WebSocket if htmx fails to load.
- Lobby actions (HTMX ws-send): `{}` = new 2P match (sender = seat 0),
  `{"diff":1|2|3}` = AI match (sender = seat 0), `{"code":"ABC123"}` =
  join (fill the free seat). Responses are `#lobby-body` HTML fragments.
- Legacy raw-protocol lobby messages still work for scripting:
  `new_ai` (+`diff`), `new`, `join` (+`code`); `hello`/`offer` are sent
  like before.
- Game client → server: `pick`, `aim`, `power`, `move`, `sel`, `fire`.
- Server → client: `hello`, `state` snapshots (terrain array only when
  dirty, 40 Hz in sim / 4 Hz otherwise), `ev` events (boom, launch,
  split, score), `result`.
- Client lerps between snapshots (25 ms interval), draws aim guide
  locally from the shared physics constants (guidance only — no logic).
- Static assets are served by explicit routes (`GET /`, `GET /client.js`)
  reading from `examples/artillery/`; the uSockets sendfile fast path in
  `serveStatic` can hang for small files, so the regular write path is
  used.

## 9. UI
- Modern glassmorphism look: gradient sky with sun and drifting clouds,
  terrain with grass cap, rounded tank hulls with a dome turret and
  recoil, glowing projectile trails with fading guidance dots, particle
  debris + shockwave rings + screen shake on blasts, pulsing toxin pools,
  wind streaks, vignette.
- Lobby (HTMX): AI difficulty buttons, create-match, join-by-code —
  server-rendered `#lobby-body` card with the 6-char code and share link
  (`/?c=CODE` auto-joins over the WS on connect).
- Top HUD: both scores, `Round n/10`, wind arrow + magnitude, timer.
- Bottom dock (active player, prep only): angle dial + bar, power bar,
  move L/R + fuel pips, weapon cards (3), FIRE.
- Controls: **click or hold+drag** on the field aims the barrel (angle
  from tank to pointer, sent throttled; plain hovering never changes the
  angle, so it stays fixed until you click again), **↑/↓** power ±1,
  **←/→** angle ±1 (fine trim), **A/D** move (fuel), **1–3** weapon,
  **Space** fire. Optimistic local updates until the
  next authoritative snapshot.
- Draft screen: weapon pool grid, pick on your turn (3 picks each).
- Game over: winner banner, final scores, "Play AI again" / "New match"
  (also HTMX ws-send — a new match starts on the same connection).
