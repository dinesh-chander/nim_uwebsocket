import fs from "node:fs";
import path from "node:path";

function bench(iterations, fn) {
  const start = process.hrtime.bigint();
  for (let i = 0; i < iterations; i++) fn();
  const elapsedNs = Number(process.hrtime.bigint() - start);
  return {
    ops: iterations / (elapsedNs / 1e9),
    ns: elapsedNs / iterations
  };
}

const warmupPasses = 10;

function benchSecondPass(iterations, fn) {
  for (let i = 0; i < warmupPasses; i++) bench(iterations, fn);
  return bench(iterations, fn);
}

function chooseIterations(payloadBytes) {
  if (payloadBytes < 64 * 1024) return 300;
  if (payloadBytes < 512 * 1024) return 120;
  if (payloadBytes < 2 * 1024 * 1024) return 40;
  return 12;
}

const dataDir = process.argv[2] && fs.existsSync(process.argv[2]) ? process.argv[2] : path.join("benchmark", "data");
const files = [
  ["twitter", "twitter.json"],
  ["citm", "citm_catalog.json"],
  ["canada", "canada.json"],
  ["historical", "historical_events.json"]
];

for (const [dataset, file] of files) {
  const payload = fs.readFileSync(path.join(dataDir, file), "utf8");
  const iterations = chooseIterations(Buffer.byteLength(payload));
  const parsed = JSON.parse(payload);
  const deser = benchSecondPass(iterations, () => { JSON.parse(payload); });
  const ser = benchSecondPass(iterations, () => { JSON.stringify(parsed); });
  console.log(JSON.stringify({
    dataset,
    payload_bytes: Buffer.byteLength(payload),
    iterations,
    deserialize_ops: deser.ops,
    deserialize_ns: deser.ns,
    serialize_ops: ser.ops,
    serialize_ns: ser.ns
  }));
}
