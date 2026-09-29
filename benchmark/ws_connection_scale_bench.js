#!/usr/bin/env node
"use strict";

const cluster = require("node:cluster");
const { performance } = require("node:perf_hooks");

const urls = (process.argv[2] || "ws://127.0.0.1:3412,ws://127.0.0.1:3413,ws://127.0.0.1:3414,ws://127.0.0.1:3415")
  .split(",")
  .map((item) => item.trim())
  .filter(Boolean);
const clientsRequested = Math.max(1, parseInt(process.argv[3] || "20000", 10));
const durationSec = Math.max(5, parseInt(process.argv[4] || "20", 10));
const openTimeoutSec = Math.max(5, parseInt(process.argv[5] || "45", 10));
const localAddresses = (process.argv[6] || "127.0.0.1")
  .split(",")
  .map((item) => item.trim())
  .filter(Boolean);
const connectBatch = Math.max(1, parseInt(process.argv[7] || "500", 10));
const connectTickMs = Math.max(10, parseInt(process.argv[8] || "100", 10));
const numWorkers = Math.max(1, parseInt(process.argv[9] || "1", 10));

if (numWorkers > 1 && cluster.isPrimary) {
  const perWorker = Math.ceil(clientsRequested / numWorkers);
  const workerResults = [];
  let finished = 0;

  for (let i = 0; i < numWorkers; i++) {
    const startIdx = i * perWorker;
    const count = Math.min(perWorker, clientsRequested - startIdx);
    if (count <= 0) break;
    const worker = cluster.fork({
      WS_WORKER_ID: String(i),
      WS_WORKER_START: String(startIdx),
      WS_WORKER_COUNT: String(count),
    });
    worker.on("message", (msg) => {
      if (msg.type === "result") {
        workerResults.push(msg.data);
        finished++;
        if (finished >= numWorkers) {
          const merged = mergeResults(workerResults);
          console.log(JSON.stringify(merged));
          process.exit(0);
        }
      }
    });
  }

  function mergeResults(results) {
    let launched = 0, opened = 0, closed = 0, errors = 0, peakOpen = 0;
    let messages = 0, openedAtMeasurementStart = 0;
    const allErrors = [];
    let totalDurationMs = 0;

    for (const r of results) {
      launched += r.launched;
      opened += r.opened;
      closed += r.closed;
      errors += r.errors;
      peakOpen += r.peakOpen;
      messages += r.messages;
      openedAtMeasurementStart += r.openedAtMeasurementStart;
      totalDurationMs += r.elapsedMeasurementMs || 0;
      for (const e of (r.sampleErrors || [])) {
        if (allErrors.length < 8) allErrors.push(e);
      }
    }
    const avgDurationSec = Math.max(0.001, (totalDurationMs / results.length) / 1000);
    const messagesPerSecTotal = messages / avgDurationSec;
    const perOpen = openedAtMeasurementStart > 0 ? messagesPerSecTotal / openedAtMeasurementStart : 0;

    return {
      urls,
      urlCount: urls.length,
      clientsRequested,
      durationSec,
      openTimeoutSec,
      localAddresses,
      localAddressCount: localAddresses.length,
      connectBatch,
      connectTickMs,
      numWorkers,
      launched,
      opened,
      closed,
      errors,
      liveOpen: 0,
      peakOpen,
      openedAtMeasurementStart,
      peakOpenDuringMeasurement: peakOpen,
      openRatio: Number((opened / clientsRequested).toFixed(4)),
      measurementReason: results[0] ? results[0].measurementReason : "unknown",
      messages,
      messagesPerSecTotal: Number(messagesPerSecTotal.toFixed(2)),
      messagesPerSecPerOpenConnection: Number(perOpen.toFixed(4)),
      expectedMessagesPerSecPerConnection: 0.5,
      sampleErrors: allErrors,
    };
  }
  return;
}

const { WebSocket } = require("ws");

const workerId = parseInt(process.env.WS_WORKER_ID || "0", 10);
const workerStartIdx = parseInt(process.env.WS_WORKER_START || "0", 10);
const workerCount = numWorkers > 1
  ? parseInt(process.env.WS_WORKER_COUNT || String(clientsRequested), 10)
  : clientsRequested;

const useExplicitLocalAddress = !(localAddresses.length === 1 && localAddresses[0] === "127.0.0.1");

const sockets = new Array(workerCount);
const sampleErrors = [];
const benchStart = performance.now();
const openDeadline = benchStart + openTimeoutSec * 1000;

let launched = 0;
let opened = 0;
let closed = 0;
let errors = 0;
let liveOpen = 0;
let peakOpen = 0;
let messages = 0;
let measurementStarted = false;
let measurementFinished = false;
let openedAtMeasurementStart = 0;
let peakOpenDuringMeasurement = 0;
let measurementStartMs = 0;
let measurementReason = "open_timeout";
let lastRateLogMs = benchStart;
let lastRateLogOpened = 0;

function maybeRecordError(err) {
  if (sampleErrors.length >= 8) return;
  const message = err && err.message ? String(err.message) : String(err || "error");
  sampleErrors.push(message.slice(0, 200));
}

function startMeasurement(reason) {
  if (measurementStarted) return;
  measurementStarted = true;
  measurementReason = reason;
  measurementStartMs = performance.now();
  openedAtMeasurementStart = opened;
  peakOpenDuringMeasurement = liveOpen;
  setTimeout(finishBenchmark, durationSec * 1000);
}

function finishBenchmark() {
  if (measurementFinished) return;
  measurementFinished = true;

  for (const ws of sockets) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      try { ws.close(); } catch (_) {}
    }
  }

  setTimeout(() => {
    const elapsedMeasurementMs = performance.now() - measurementStartMs;
    const elapsedMeasurementSec = Math.max(0.001, elapsedMeasurementMs / 1000);
    const messagesPerSecTotal = messages / elapsedMeasurementSec;
    const perOpenConnection = openedAtMeasurementStart > 0
      ? messagesPerSecTotal / openedAtMeasurementStart
      : 0;

    const out = {
      urls,
      urlCount: urls.length,
      clientsRequested: workerCount,
      durationSec,
      openTimeoutSec,
      localAddresses,
      localAddressCount: localAddresses.length,
      connectBatch,
      connectTickMs,
      launched,
      opened,
      closed,
      errors,
      liveOpen,
      peakOpen,
      openedAtMeasurementStart,
      peakOpenDuringMeasurement,
      openRatio: Number((opened / workerCount).toFixed(4)),
      measurementReason,
      messages,
      messagesPerSecTotal: Number(messagesPerSecTotal.toFixed(2)),
      messagesPerSecPerOpenConnection: Number(perOpenConnection.toFixed(4)),
      expectedMessagesPerSecPerConnection: 0.5,
      sampleErrors,
      elapsedMeasurementMs: Number(elapsedMeasurementMs.toFixed(0)),
    };

    if (numWorkers > 1) {
      process.send({ type: "result", data: out });
      setTimeout(() => process.exit(0), 500);
    } else {
      console.log(JSON.stringify(out));
      process.exit(0);
    }
  }, 1500);
}

function maybeStartMeasurementFromState() {
  if (opened >= workerCount) {
    startMeasurement("all_open");
  } else if (performance.now() >= openDeadline) {
    startMeasurement("open_timeout");
  }
}

function createSocket(localIdx) {
  const globalIdx = workerStartIdx + localIdx;
  const url = urls[globalIdx % urls.length];
  const localAddress = localAddresses[globalIdx % localAddresses.length];
  const options = {
    perMessageDeflate: false,
    handshakeTimeout: openTimeoutSec * 1000
  };
  if (useExplicitLocalAddress) {
    options.localAddress = localAddress;
  }
  const ws = new WebSocket(url, options);
  ws.binaryType = "arraybuffer";
  ws.__opened = false;
  sockets[localIdx] = ws;

  ws.on("open", () => {
    if (!ws.__opened) {
      ws.__opened = true;
      opened += 1;
      liveOpen += 1;
      if (liveOpen > peakOpen) peakOpen = liveOpen;
      if (measurementStarted && liveOpen > peakOpenDuringMeasurement) {
        peakOpenDuringMeasurement = liveOpen;
      }
    }
    maybeStartMeasurementFromState();
  });

  ws.on("message", () => {
    if (measurementStarted && !measurementFinished) {
      messages += 1;
    }
  });

  ws.on("error", (err) => {
    errors += 1;
    maybeRecordError(err);
    maybeStartMeasurementFromState();
  });

  ws.on("close", () => {
    closed += 1;
    if (ws.__opened) {
      liveOpen = Math.max(0, liveOpen - 1);
    }
  });
}

const launchTimer = setInterval(() => {
  let created = 0;
  while (launched < workerCount && created < connectBatch) {
    createSocket(launched);
    launched += 1;
    created += 1;
  }
  const now = performance.now();
  if (now - lastRateLogMs >= 2000) {
    const dt = (now - lastRateLogMs) / 1000;
    const rate = Math.round((opened - lastRateLogOpened) / dt);
    process.stderr.write(
      `[ws-scale w${workerId}] launched=${launched} opened=${opened} live=${liveOpen} errors=${errors} rate=${rate}/s\n`
    );
    lastRateLogMs = now;
    lastRateLogOpened = opened;
  }
  if (launched >= workerCount) {
    clearInterval(launchTimer);
  }
  maybeStartMeasurementFromState();
}, connectTickMs);

setTimeout(() => {
  clearInterval(launchTimer);
  maybeStartMeasurementFromState();
}, openTimeoutSec * 1000 + connectTickMs);
