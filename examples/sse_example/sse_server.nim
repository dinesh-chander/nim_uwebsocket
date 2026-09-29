## SSE (Server-Sent Events) example for nim_express
##
## Demonstrates:
##   - sseStart with retry interval
##   - sseEvent with named events, IDs, and multiline data
##   - sseComment for keep-alive pings
##   - sseEnd to close streams
##   - Multiple concurrent SSE streams
##   - Last-Event-ID reconnection support
##
## Run and open http://localhost:3000 in a browser.

import std/times
import ../../nim_express/src/nim_express
import ../../nim_express/src/nim_express/fastrand

var eventClients: seq[Response] = @[]
var counterClients: seq[Response] = @[]

var globalCounter = 0
var eventId = 0

const IndexHtml = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SSE Demo — nim_express</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, -apple-system, sans-serif; background: #0f172a; color: #e2e8f0; min-height: 100vh; padding: 2rem; }
  h1 { font-size: 1.75rem; margin-bottom: 1.5rem; color: #38bdf8; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; max-width: 960px; margin: 0 auto; }
  .card { background: #1e293b; border-radius: 0.75rem; padding: 1.25rem; border: 1px solid #334155; }
  .card h2 { font-size: 1.1rem; margin-bottom: 0.75rem; color: #94a3b8; }
  .status { font-size: 0.8rem; padding: 0.25rem 0.6rem; border-radius: 9999px; display: inline-block; margin-bottom: 0.75rem; }
  .status.connected { background: #065f46; color: #6ee7b7; }
  .status.disconnected { background: #7f1d1d; color: #fca5a5; }
  #events, #counter { list-style: none; max-height: 400px; overflow-y: auto; font-family: 'SF Mono', 'Fira Code', monospace; font-size: 0.82rem; line-height: 1.6; }
  #events li, #counter li { padding: 0.3rem 0; border-bottom: 1px solid #1e293b; }
  .event-time { color: #38bdf8; } .event-name { color: #a78bfa; } .event-id { color: #64748b; } .event-data { color: #e2e8f0; }
  .counter-val { font-size: 2.5rem; font-weight: 700; color: #22d3ee; text-align: center; padding: 1rem 0; }
  footer { text-align: center; margin-top: 2rem; color: #475569; font-size: 0.8rem; }
</style>
</head>
<body>
<h1>Server-Sent Events Demo</h1>
<div class="grid">
  <div class="card">
    <h2>/events — Mixed event stream</h2>
    <span id="events-status" class="status disconnected">disconnected</span>
    <ul id="events"></ul>
  </div>
  <div class="card">
    <h2>/events/counter — Counter stream</h2>
    <span id="counter-status" class="status disconnected">disconnected</span>
    <div id="counter-value" class="counter-val">—</div>
    <ul id="counter"></ul>
  </div>
</div>
<footer>nim_express SSE example</footer>
<script>
(function() {
  function connectEvents() {
    var ul = document.getElementById('events');
    var badge = document.getElementById('events-status');
    var es = new EventSource('/events');

    es.onopen = function() {
      badge.textContent = 'connected';
      badge.className = 'status connected';
    };

    es.addEventListener('time', function(e) {
      var li = document.createElement('li');
      li.innerHTML = '<span class="event-name">[time]</span> '
        + '<span class="event-id">#' + e.lastEventId + '</span> '
        + '<span class="event-data">' + e.data + '</span>';
      ul.prepend(li);
      if (ul.children.length > 200) ul.removeChild(ul.lastChild);
    });

    es.addEventListener('notification', function(e) {
      var li = document.createElement('li');
      li.innerHTML = '<span class="event-name">[notification]</span> '
        + '<span class="event-id">#' + e.lastEventId + '</span> '
        + '<span class="event-data">' + e.data + '</span>';
      ul.prepend(li);
      if (ul.children.length > 200) ul.removeChild(ul.lastChild);
    });

    es.addEventListener('stats', function(e) {
      var li = document.createElement('li');
      li.innerHTML = '<span class="event-name">[stats]</span> '
        + '<span class="event-id">#' + e.lastEventId + '</span> '
        + '<span class="event-data">' + e.data + '</span>';
      ul.prepend(li);
      if (ul.children.length > 200) ul.removeChild(ul.lastChild);
    });

    es.onerror = function() {
      badge.textContent = 'reconnecting…';
      badge.className = 'status disconnected';
    };
  }

  function connectCounter() {
    var ul = document.getElementById('counter');
    var badge = document.getElementById('counter-status');
    var valDiv = document.getElementById('counter-value');
    var es = new EventSource('/events/counter');

    es.onopen = function() {
      badge.textContent = 'connected';
      badge.className = 'status connected';
    };

    es.onmessage = function(e) {
      valDiv.textContent = e.data;
      var li = document.createElement('li');
      li.innerHTML = '<span class="event-id">#' + e.lastEventId + '</span> '
        + '<span class="event-data">count = ' + e.data + '</span>';
      ul.prepend(li);
      if (ul.children.length > 100) ul.removeChild(ul.lastChild);
    };

    es.onerror = function() {
      badge.textContent = 'reconnecting…';
      badge.className = 'status disconnected';
    };
  }

  connectEvents();
  connectCounter();
})();
</script>
</body>
</html>"""

const Notifications = [
  "Build succeeded",
  "New user signed up",
  "Payment processed",
  "Cache cleared",
  "Deployment started",
  "Health check passed",
  "Config reloaded",
  "Backup completed"
]

proc broadcastEvents() =
  inc globalCounter

  var dead: seq[int] = @[]
  for i in 0..<eventClients.len:
    let res = eventClients[i]
    inc eventId
    let idStr = $eventId

    if globalCounter mod 10 == 0:
      if not res.sseEvent(
        now().format("yyyy-MM-dd HH:mm:ss"),
        event = "time",
        id = idStr
      ):
        dead.add(i)
        continue

    if globalCounter mod 30 == 0:
      let note = Notifications[fastRandRange(Notifications.len)]
      inc eventId
      if not res.sseEvent(note, event = "notification", id = $(eventId)):
        dead.add(i)
        continue

    if globalCounter mod 50 == 0:
      let multilineData = "clients: " & $eventClients.len & "\n" &
                          "counter_clients: " & $counterClients.len & "\n" &
                          "ticks: " & $globalCounter
      inc eventId
      if not res.sseEvent(multilineData, event = "stats", id = $(eventId)):
        dead.add(i)
        continue

    if globalCounter mod 150 == 0:
      discard res.sseComment("keep-alive")

  for i in countdown(dead.high, 0):
    eventClients.delete(dead[i])

  dead.setLen(0)
  for i in 0..<counterClients.len:
    let res = counterClients[i]
    inc eventId
    if not res.sseEvent($globalCounter, id = $(eventId)):
      dead.add(i)

  for i in countdown(dead.high, 0):
    counterClients.delete(dead[i])

proc main() =
  let app = newExpressApp()

  app.get("/") do (req: Request, res: Response):
    res.html(IndexHtml)

  app.get("/events") do (req: Request, res: Response):
    let lastId = req.get("last-event-id")
    if lastId.len > 0:
      echo "Client reconnected with Last-Event-ID: ", lastId

    if not res.sseStart(retryMs = 3000):
      res.status(500).send("Failed to start SSE stream")
      return

    discard res.sseComment("connected to /events stream")

    inc eventId
    discard res.sseEvent(
      now().format("yyyy-MM-dd HH:mm:ss"),
      event = "time",
      id = $(eventId)
    )

    eventClients.add(res)

  app.get("/events/counter") do (req: Request, res: Response):
    if not res.sseStart(retryMs = 2000):
      res.status(500).send("Failed to start SSE stream")
      return

    discard res.sseComment("connected to counter stream")

    inc eventId
    discard res.sseEvent($globalCounter, id = $(eventId))

    counterClients.add(res)

  app.setInterval(broadcastEvents, 1000)

  echo "SSE example server starting..."
  app.listen(3000) do (success: bool):
    if success:
      echo "Listening on http://localhost:3000"
      echo "  GET /              — HTML page with SSE client"
      echo "  GET /events        — SSE stream (time, notifications, stats)"
      echo "  GET /events/counter — SSE counter stream"
    else:
      echo "Failed to start server!"
      quit(1)

when isMainModule:
  main()
