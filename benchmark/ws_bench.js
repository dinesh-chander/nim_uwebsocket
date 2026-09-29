#!/usr/bin/env node
"use strict";

const { performance } = require("node:perf_hooks");
const { WebSocket } = require("ws");

const url = process.argv[2] || "ws://127.0.0.1:3100";
const clients = Math.max(1, parseInt(process.argv[3] || "200", 10));
const durationSec = Math.max(1, parseInt(process.argv[4] || "15", 10));
const payloadBytes = Math.max(12, parseInt(process.argv[5] || "64", 10));
const maxInflight = Math.max(1, parseInt(process.argv[6] || "16", 10));

const benchStart = performance.now();
const deadline = benchStart + durationSec * 1000;

let opened = 0;
let closed = 0;
let sent = 0;
let recv = 0;
let errors = 0;
let inFlight = 0;
let latencyMsSum = 0;
let latencyMsMax = 0;

// Approximate percentile tracking with bounded memory.
const LATENCY_SAMPLE_MAX = 200000;
const LATENCY_SAMPLE_EVERY = 32;
const latencySamples = [];
let latencySampleCounter = 0;

const sockets = [];
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function recordLatencySample(latencyMs) {
  latencySampleCounter += 1;
  if ((latencySampleCounter % LATENCY_SAMPLE_EVERY) !== 0) return;
  if (latencySamples.length >= LATENCY_SAMPLE_MAX) return;
  latencySamples.push(latencyMs);
}

function quantile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.floor((sorted.length - 1) * p)));
  return sorted[idx];
}

function makePayload() {
  const nowUs = BigInt(Math.floor(performance.now() * 1000));
  let prefix = nowUs.toString().padStart(12, "0");
  if (prefix.length > 12) prefix = prefix.slice(-12);
  const bodyLen = payloadBytes - 12;
  let body = "";
  for (let i = 0; i < bodyLen; i++) body += String.fromCharCode(65 + (i % 26));
  return encoder.encode(prefix + body);
}

function parseLatencyMs(data) {
  try {
    const msg = typeof data === "string" ? data : decoder.decode(data);
    const tsUs = Number(msg.slice(0, 12));
    if (!Number.isFinite(tsUs)) return 0;
    const nowUs = performance.now() * 1000;
    return Math.max(0, (nowUs - tsUs) / 1000);
  } catch {
    return 0;
  }
}

function pump(ws) {
  if (performance.now() >= deadline) return;
  while (ws.readyState === ws.OPEN && ws.__inflight < maxInflight && performance.now() < deadline) {
    const payload = makePayload();
    ws.send(payload);
    ws.__inflight++;
    inFlight++;
    sent++;
  }
}

for (let i = 0; i < clients; i++) {
  const ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";
  ws.__inflight = 0;
  ws.__closing = false;
  sockets.push(ws);

  ws.onopen = () => {
    opened++;
    pump(ws);
  };

  ws.onmessage = (evt) => {
    recv++;
    if (ws.__inflight > 0) {
      ws.__inflight--;
      inFlight--;
    }
    const l = parseLatencyMs(evt.data);
    latencyMsSum += l;
    if (l > latencyMsMax) latencyMsMax = l;
    recordLatencySample(l);
    pump(ws);
  };

  ws.onerror = () => {
    errors++;
  };

  ws.onclose = () => {
    closed++;
  };
}

function stopAll() {
  for (const ws of sockets) {
    if (!ws.__closing && ws.readyState === ws.OPEN) {
      ws.__closing = true;
      try {
        ws.close();
      } catch {
        // ignore close errors on teardown
      }
    }
  }
}

setTimeout(() => {
  stopAll();
}, durationSec * 1000 + 250);

setTimeout(() => {
  const elapsedSec = (performance.now() - benchStart) / 1000;
  const mps = recv / elapsedSec;
  const avgLatency = recv > 0 ? latencyMsSum / recv : 0;

  const sortedLatency = latencySamples.slice().sort((a, b) => a - b);
  const p50 = quantile(sortedLatency, 0.50);
  const p95 = quantile(sortedLatency, 0.95);
  const p99 = quantile(sortedLatency, 0.99);

  const out = {
    url,
    clients,
    durationSec,
    payloadBytes,
    maxInflight,
    opened,
    closed,
    sent,
    recv,
    errors,
    rttMsgPerSec: Number(mps.toFixed(2)),
    avgLatencyMs: Number(avgLatency.toFixed(3)),
    p50LatencyMs: Number(p50.toFixed(3)),
    p95LatencyMs: Number(p95.toFixed(3)),
    p99LatencyMs: Number(p99.toFixed(3)),
    maxLatencyMs: Number(latencyMsMax.toFixed(3)),
    latencySamples: sortedLatency.length,
    inFlight
  };
  console.log(JSON.stringify(out));
  process.exit(0);
}, durationSec * 1000 + 1200);
