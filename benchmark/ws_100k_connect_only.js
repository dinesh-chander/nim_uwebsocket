const crypto = require('crypto');
const net = require('net');

const DEST_IP = process.argv[2] || '127.0.0.1';
const DEST_PORT = parseInt(process.argv[3] || '3100');
const TARGET_CONNS = parseInt(process.argv[4] || '20000');
const CONNECT_RATE = parseInt(process.argv[5] || '500');
const SRC_IP = process.argv[6] || undefined;

let connected = 0;
let attempted = 0;
let errors = 0;
let lastErrorMsg = '';
const sockets = [];
let rampDone = false;

function connectOne() {
  if (attempted >= TARGET_CONNS) return;
  attempted++;
  const opts = { host: DEST_IP, port: DEST_PORT };
  if (SRC_IP) opts.localAddress = SRC_IP;

  const sock = net.createConnection(opts, () => {
    const key = crypto.randomBytes(16).toString('base64');
    sock.write(
      `GET / HTTP/1.1\r\nHost: ${DEST_IP}:${DEST_PORT}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`
    );
    let gotUpgrade = false;
    let buf = Buffer.alloc(0);
    sock.on('data', (chunk) => {
      if (!gotUpgrade) {
        buf = Buffer.concat([buf, chunk]);
        if (buf.indexOf('\r\n\r\n') >= 0) {
          gotUpgrade = true;
          connected++;
          buf = null;
          sock.pause();
        }
      }
    });
  });

  sock.setNoDelay(true);
  try { sock.setRecvBufferSize(2048); } catch(e) {}
  try { sock.setSendBufferSize(2048); } catch(e) {}

  sock.on('error', (e) => {
    errors++;
    lastErrorMsg = e.code || e.message;
  });
  sock.on('close', () => { connected--; });
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
  console.log(`dst=${DEST_IP} src=${SRC_IP||'auto'} connected=${connected} attempted=${attempted} errors=${errors} ramp=${rampDone} lastErr=${lastErrorMsg}`);
}, 5000);
