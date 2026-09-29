const WebSocket = require("ws");

const URL = process.argv[2] || "ws://127.0.0.1:3200";
const CONCURRENCY = parseInt(process.argv[3] || "10", 10);
const DURATION_S = parseInt(process.argv[4] || "15", 10);
const ACTIONS = ["query", "order", "cancel", "status", "inventory", "refund"];

let totalSent = 0;
let totalRecv = 0;
let totalBytes = 0;
let latencies = [];
let errors = 0;
let connected = 0;

function makeRequest() {
  const id = (totalSent++).toString(36);
  const action = ACTIONS[Math.floor(Math.random() * ACTIONS.length)];
  const ts = Date.now();
  return {
    json: JSON.stringify({
      requestId: id,
      action: action,
      userId: "user_" + Math.floor(Math.random() * 10000),
      sessionToken: "tok_" + id + "_" + Math.random().toString(36).slice(2, 10),
      params: {
        productId: "prod_" + Math.floor(Math.random() * 500),
        quantity: Math.floor(Math.random() * 10) + 1,
        region: ["us-west", "us-east", "eu-west", "ap-south"][
          Math.floor(Math.random() * 4)
        ],
      },
      timestamp: ts,
    }),
    sentAt: ts,
  };
}

function connect(idx) {
  return new Promise((resolve) => {
    const ws = new WebSocket(URL);
    ws.on("open", () => {
      connected++;
      resolve(ws);
    });
    ws.on("message", (data) => {
      totalRecv++;
      totalBytes += data.length;
      // parse to measure overhead
      try {
        JSON.parse(data);
      } catch (e) {}
    });
    ws.on("error", (e) => {
      errors++;
    });
    ws.on("close", () => {
      connected--;
    });
  });
}

async function main() {
  console.log(
    `Realistic WS bench: ${CONCURRENCY} clients, ${DURATION_S}s, target: ${URL}`
  );

  const sockets = [];
  for (let i = 0; i < CONCURRENCY; i++) {
    sockets.push(await connect(i));
  }
  console.log(`${connected} clients connected`);

  const start = Date.now();
  const end = start + DURATION_S * 1000;

  // fire-and-forget loop per socket
  const intervals = sockets.map((ws) => {
    return setInterval(() => {
      if (Date.now() >= end || ws.readyState !== WebSocket.OPEN) return;
      const req = makeRequest();
      ws.send(req.json);
    }, 0);
  });

  await new Promise((r) => setTimeout(r, DURATION_S * 1000 + 500));

  intervals.forEach(clearInterval);

  const elapsed = (Date.now() - start) / 1000;
  const sentPerSec = Math.floor(totalSent / elapsed);
  const recvPerSec = Math.floor(totalRecv / elapsed);
  const bytesPerSec = Math.floor(totalBytes / elapsed);

  console.log(`\n--- Results (${elapsed.toFixed(1)}s) ---`);
  console.log(`  Sent:     ${totalSent.toLocaleString()} (${sentPerSec.toLocaleString()}/sec)`);
  console.log(`  Received: ${totalRecv.toLocaleString()} (${recvPerSec.toLocaleString()}/sec)`);
  console.log(`  Throughput: ${(bytesPerSec / 1024 / 1024).toFixed(1)} MB/sec`);
  console.log(`  Avg response size: ${totalRecv > 0 ? Math.floor(totalBytes / totalRecv) : 0} bytes`);
  console.log(`  Errors: ${errors}`);

  sockets.forEach((ws) => {
    try { ws.close(); } catch (e) {}
  });
  setTimeout(() => process.exit(0), 1000);
}

main();
