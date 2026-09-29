#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BIN="${APP_BIN:-${ROOT_DIR}/nim_express/bin/todo_sqlite_mvc_app}"
WORKERS="${WORKERS:-4}"
BASE_PORT="${BASE_PORT:-3600}"
DB_PREFIX="${DB_PREFIX:-/tmp/nim_port_sharded}"
PROFILE="${NIM_EXPRESS_PROFILE:-linux-throughput}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/benchmark/reports/port_sharded_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "${OUT_DIR}"

if [[ ! -x "${APP_BIN}" ]]; then
  echo "app binary not found: ${APP_BIN}" >&2
  exit 1
fi

pids=()
cleanup() {
  if ((${#pids[@]} > 0)); then
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" 2>/dev/null || true
      fi
    done
  fi
}
trap cleanup EXIT

printf "# Port-sharded cluster\n" >"${OUT_DIR}/README.md"
printf "workers=%s\nbase_port=%s\nprofile=%s\n\n" "$WORKERS" "$BASE_PORT" "$PROFILE" >>"${OUT_DIR}/README.md"

printf "frontend nim_express_frontend\n  bind *:3000\n  mode http\n  default_backend nim_express_backend\n\nbackend nim_express_backend\n  mode http\n  balance roundrobin\n" >"${OUT_DIR}/haproxy_backend.cfg"

for i in $(seq 0 $((WORKERS - 1))); do
  port=$((BASE_PORT + i))
  db="${DB_PREFIX}_${port}.db"
  log="${OUT_DIR}/worker_${i}.log"
  rm -f "${db}" "${db}-wal" "${db}-shm"
  TODO_DB_PATH="${db}" PORT="${port}" TODO_LOG=0 NIM_EXPRESS_PROFILE="${PROFILE}" "${APP_BIN}" >"${log}" 2>&1 &
  pid=$!
  pids+=("$pid")
  echo "server w${i} 127.0.0.1:${port} check" >>"${OUT_DIR}/haproxy_backend.cfg"
  echo "worker=${i} port=${port} pid=${pid} db=${db}" >>"${OUT_DIR}/workers.txt"
done

echo "[port-sharded] workers started"
echo "[port-sharded] mapping: ${OUT_DIR}/workers.txt"
echo "[port-sharded] haproxy backend config: ${OUT_DIR}/haproxy_backend.cfg"
echo "[port-sharded] press Ctrl+C to stop"

while true; do
  sleep 1
done
