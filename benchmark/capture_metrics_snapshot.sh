#!/usr/bin/env bash
set -euo pipefail

URL="${1:-http://127.0.0.1:3000/metrics}"
OUT="${2:-benchmark/reports/metrics_snapshot_$(date +%Y%m%d_%H%M%S).json}"
mkdir -p "$(dirname "$OUT")"

if ! curl -fsS "$URL" >"$OUT"; then
  echo "failed to fetch metrics from $URL" >&2
  exit 1
fi

echo "[metrics] wrote ${OUT}"
