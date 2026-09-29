const WebSocket = require("ws");

const url = process.argv[2] || "ws://127.0.0.1:3100";
const totalTarget = parseInt(process.argv[3] || "100000");
const batchSize = parseInt(process.argv[4] || "5000");
const batchDelayMs = parseInt(process.argv[5] || "500");
const holdSeconds = parseInt(process.argv[6] || "30");

let connected = 0;
let failed = 0;
let messagesReceived = 0;
let bytesReceived = 0;
let sockets = [];

function connectBatch(startIdx, count) {
  return new Promise((resolve) => {
    let pending = count;
    for (let i = 0; i < count; i++) {
      const ws = new WebSocket(url);
      ws.binaryType = "arraybuffer";

      ws.on("open", () => {
        connected++;
        sockets.push(ws);
        if (--pending === 0) resolve();
      });

      ws.on("message", (data) => {
        messagesReceived++;
        bytesReceived += data.byteLength || data.length;
      });

      ws.on("error", (err) => {
        failed++;
        if (failed <= 5) console.log(JSON.stringify({phase:"error", error: err.message, code: err.code, idx: startIdx + i}));
        if (--pending === 0) resolve();
      });

      ws.on("close", () => {
        connected--;
      });
    }

    setTimeout(() => resolve(), batchDelayMs * 3);
  });
}

async function run() {
  console.log(JSON.stringify({
    phase: "config",
    url,
    totalTarget,
    batchSize,
    batchDelayMs,
    holdSeconds
  }));

  let batchNum = 0;
  for (let i = 0; i < totalTarget; i += batchSize) {
    const count = Math.min(batchSize, totalTarget - i);
    batchNum++;
    await connectBatch(i, count);
    console.log(JSON.stringify({
      phase: "batch",
      batch: batchNum,
      connected,
      failed,
      messagesReceived,
      bytesReceived
    }));
    if (i + count < totalTarget) {
      await new Promise(r => setTimeout(r, batchDelayMs));
    }
  }

  console.log(JSON.stringify({
    phase: "connected",
    connected,
    failed,
    messagesReceived,
    bytesReceived
  }));

  const holdStart = Date.now();
  const statsInterval = setInterval(() => {
    const elapsed = ((Date.now() - holdStart) / 1000).toFixed(1);
    console.log(JSON.stringify({
      phase: "holding",
      elapsedSec: parseFloat(elapsed),
      connected,
      messagesReceived,
      bytesReceived,
      msgPerSec: Math.round(messagesReceived / parseFloat(elapsed))
    }));
  }, 5000);

  await new Promise(r => setTimeout(r, holdSeconds * 1000));
  clearInterval(statsInterval);

  console.log(JSON.stringify({
    phase: "done",
    connected,
    failed,
    totalMessagesReceived: messagesReceived,
    totalBytesReceived: bytesReceived,
    avgMsgPerSec: Math.round(messagesReceived / holdSeconds)
  }));

  for (const ws of sockets) {
    try { ws.close(); } catch (e) {}
  }
  setTimeout(() => process.exit(0), 2000);
}

run().catch(console.error);
