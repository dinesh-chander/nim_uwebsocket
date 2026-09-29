const { WebSocket: WebSocketCtor } = require('ws');
const url = process.argv[2] || 'ws://127.0.0.1:3400/ws';
const connections = parseInt(process.argv[3] || '200', 10);
const durationSec = parseInt(process.argv[4] || '10', 10);
const payloadLen = parseInt(process.argv[5] || '32', 10);

const payload = 'x'.repeat(Math.max(1, payloadLen));
let opened = 0;
let closed = 0;
let sendCount = 0;
let recvCount = 0;
let errors = 0;
let started = false;
let stopping = false;
const sockets = [];

function maybeStart() {
  if (!started && opened === connections) {
    started = true;
    for (const ws of sockets) {
      if (ws.readyState === WebSocketCtor.OPEN) {
        ws.send(payload);
        sendCount++;
      }
    }
    setTimeout(stop, durationSec * 1000);
  }
}

function stop() {
  if (stopping) return;
  stopping = true;
  for (const ws of sockets) {
    try { ws.close(); } catch (_) {}
  }
  setTimeout(() => {
    const mps = recvCount / durationSec;
    console.log(JSON.stringify({
      url,
      connections,
      durationSec,
      payloadLen,
      opened,
      closed,
      sendCount,
      recvCount,
      msgPerSec: mps,
      errors
    }));
    process.exit(0);
  }, 600);
}

setTimeout(() => {
  if (!started) {
    stop();
  }
}, 12000);

for (let i = 0; i < connections; i++) {
  const ws = new WebSocketCtor(url);
  sockets.push(ws);

  ws.onopen = () => {
    opened++;
    maybeStart();
  };

  ws.onmessage = () => {
    recvCount++;
    if (!stopping && ws.readyState === WebSocketCtor.OPEN) {
      ws.send(payload);
      sendCount++;
    }
  };

  ws.onerror = () => {
    errors++;
  };

  ws.onclose = () => {
    closed++;
  };
}
