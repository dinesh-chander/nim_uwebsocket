const http = require('http');
const crypto = require('crypto');
const net = require('net');

const DEST_IP = process.argv[2] || '127.0.0.1';
const DEST_PORT = parseInt(process.argv[3] || '3100');
const TARGET_CONNS = parseInt(process.argv[4] || '25000');
const CONNECT_RATE = parseInt(process.argv[5] || '2000');
const SRC_IP = process.argv[6] || undefined;

let connected = 0;
let attempted = 0;
let errors = 0;
let messagesReceived = 0;
const sockets = [];
let rampDone = false;

function doWsHandshake(sock) {
  const key = crypto.randomBytes(16).toString('base64');
  sock.write(
    `GET / HTTP/1.1\r\nHost: ${DEST_IP}:${DEST_PORT}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`
  );
  let upgraded = false;
  let buf = Buffer.alloc(0);
  sock.on('data', (chunk) => {
    if (!upgraded) {
      buf = Buffer.concat([buf, chunk]);
      const headerEnd = buf.indexOf('\r\n\r\n');
      if (headerEnd >= 0) {
        upgraded = true;
        connected++;
        const remaining = buf.slice(headerEnd + 4);
        if (remaining.length > 0) countWsFrames(remaining);
      }
    } else {
      countWsFrames(chunk);
    }
  });
}

function countWsFrames(data) {
  let offset = 0;
  while (offset < data.length) {
    if (offset + 2 > data.length) break;
    const byte2 = data[offset + 1] & 0x7f;
    let payloadLen = byte2;
    let headerLen = 2;
    if (byte2 === 126) {
      if (offset + 4 > data.length) break;
      payloadLen = data.readUInt16BE(offset + 2);
      headerLen = 4;
    } else if (byte2 === 127) {
      if (offset + 10 > data.length) break;
      payloadLen = Number(data.readBigUInt64BE(offset + 2));
      headerLen = 10;
    }
    if (offset + headerLen + payloadLen > data.length) break;
    messagesReceived++;
    offset += headerLen + payloadLen;
  }
}

function connectOne() {
  if (attempted >= TARGET_CONNS) return;
  attempted++;
  const opts = {
    host: DEST_IP,
    port: DEST_PORT,
  };
  if (SRC_IP) opts.localAddress = SRC_IP;
  const sock = net.createConnection(opts, () => {
    doWsHandshake(sock);
  });
  sock.setNoDelay(true);
  try { sock.setRecvBufferSize(4096); } catch(e) {}
  try { sock.setSendBufferSize(4096); } catch(e) {}
  sock.on('error', (e) => {
    errors++;
    if (errors <= 3) console.log(`error: ${e.code || e.message}`);
  });
  sock.on('close', () => {
    connected--;
  });
  sockets.push(sock);
}

let batchTimer = setInterval(() => {
  const batch = Math.min(CONNECT_RATE, TARGET_CONNS - attempted);
  for (let i = 0; i < batch; i++) connectOne();
  if (attempted >= TARGET_CONNS) {
    clearInterval(batchTimer);
    rampDone = true;
  }
}, 1000);

setInterval(() => {
  console.log(`dst=${DEST_IP}:${DEST_PORT} src=${SRC_IP||'auto'} connected=${connected} attempted=${attempted} errors=${errors} msgs=${messagesReceived} rampDone=${rampDone}`);
}, 5000);
