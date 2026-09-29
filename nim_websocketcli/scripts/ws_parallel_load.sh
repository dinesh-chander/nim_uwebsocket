#!/usr/bin/env bash
## Fan out WebSocket load across several websocketload processes (~1M aggregate connections).
## Requires sysctl + loopback aliases from ws_scale_linux.sh and high ``ulimit -n``.
##
## Usage (from repo root):
##   chmod +x nim_websocketcli/scripts/ws_parallel_load.sh
##   HOST=127.0.0.1 PORT=3400 PATH_WS=/ WORKERS=6 CHUNK=166667 THREADS=24 PARALLEL_FANOUT=2 \\
##     bash nim_websocketcli/scripts/ws_parallel_load.sh
##
## Env:
##   WEBSOCKETLOAD   Path to websocketload binary (default: repo-root nim_websocketcli/websocketload)
##   WORKERS         Number of websocketload processes (six × CHUNK ≈ 1M aggregate)
##   CHUNK           Connections per process (default 166667)
##   THREADS         ``-t`` per client (default 24)
##   BINDLB          --bind-loopbacks N (default 253)
##   DURATION        Seconds each client runs (default 300)
##   PARALLEL_FANOUT Max concurrent websocketload processes (default 2 — avoids SIGSEGV / server crashes)
##   STAGGER_SEC     Delay between spawns inside one fan-out batch (default 25)
##   BATCH_GAP_SEC   Pause between batches after the previous batch exits (default 45)
##   WSLOAD_RAMP_SEC            If set, pass ``--ramp-sec`` to each websocketload
##   WSLOAD_CONNECT_RETRIES   If set, pass ``--connect-retries``
##   WSLOAD_RETRY_DELAY_MS    If set, pass ``--retry-delay-ms``

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN="${WEBSOCKETLOAD:-$REPO_ROOT/nim_websocketcli/websocketload}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ws_parallel_load.sh must run on Linux."
  exit 1
fi

WSLOAD_EXTRA=()
if [[ -n "${WSLOAD_RAMP_SEC:-}" ]]; then
  WSLOAD_EXTRA+=(--ramp-sec "$WSLOAD_RAMP_SEC")
fi
if [[ -n "${WSLOAD_CONNECT_RETRIES:-}" ]]; then
  WSLOAD_EXTRA+=(--connect-retries "$WSLOAD_CONNECT_RETRIES")
fi
if [[ -n "${WSLOAD_RETRY_DELAY_MS:-}" ]]; then
  WSLOAD_EXTRA+=(--retry-delay-ms "$WSLOAD_RETRY_DELAY_MS")
fi

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3400}"
PATH_WS="${PATH_WS:-/}"
WORKERS="${WORKERS:-6}"
## Sum ``WORKERS`` × ``CHUNK`` ≈ 1_000_002 — split stays ≤ ~360k sockets per ``websocketload`` (15000 × 24 threads).
CHUNK="${CHUNK:-166667}"
THREADS="${THREADS:-24}"
BINDLB="${BINDLB:-253}"
DURATION="${DURATION:-300}"
PARALLEL_FANOUT="${PARALLEL_FANOUT:-2}"
STAGGER_SEC="${STAGGER_SEC:-25}"
BATCH_GAP_SEC="${BATCH_GAP_SEC:-45}"

if [[ ! -x "$BIN" ]]; then
  echo "websocketload not executable: $BIN (build: make websocketload)"
  exit 1
fi

if [[ "${SKIP_PREFLIGHT:-0}" != "1" ]]; then
  bash "$REPO_ROOT/nim_websocketcli/scripts/ws_preflight_500k.sh"
fi

if [[ "$THREADS" -gt 24 ]]; then
  echo "THREADS must be ≤ 24 (websocketload guard)."
  exit 1
fi

ulimit -n "${ULIMIT_NOFILE:-1048576}" || true

if [[ "$PARALLEL_FANOUT" -lt 1 ]]; then
  echo "PARALLEL_FANOUT must be ≥ 1"
  exit 1
fi

failed=0
idx=1
while (( idx <= WORKERS )); do
  pids=()
  batch_started=0
  while (( batch_started < PARALLEL_FANOUT && idx <= WORKERS )); do
    log="/tmp/ws_parallel_${idx}.log"
    echo "[parallel $idx/$WORKERS fanout≤$PARALLEL_FANOUT] websocketload -c $CHUNK -t $THREADS → $log"
    "$BIN" -h "$HOST" -p "$PORT" --path "$PATH_WS" -c "$CHUNK" -d "$DURATION" \
      --bind-loopbacks "$BINDLB" --open-msgs 0 --no-reply-on-recv -t "$THREADS" \
      "${WSLOAD_EXTRA[@]}" \
      >"$log" 2>&1 &
    pids+=("$!")
    batch_started=$((batch_started + 1))
    idx=$((idx + 1))
    if (( batch_started < PARALLEL_FANOUT && idx <= WORKERS )) && [[ "$STAGGER_SEC" != "0" ]]; then
      sleep "$STAGGER_SEC"
    fi
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  if (( idx <= WORKERS )) && [[ "$BATCH_GAP_SEC" != "0" ]]; then
    echo "[pause ${BATCH_GAP_SEC}s before next batch]"
    sleep "$BATCH_GAP_SEC"
  fi
done

echo ""
echo "--- summary (tail of each log) ---"
for i in $(seq 1 "$WORKERS"); do
  echo ""
  echo "=== worker $i ($CHUNK conns) ==="
  tail -14 "/tmp/ws_parallel_${i}.log"
done

exit "$failed"
