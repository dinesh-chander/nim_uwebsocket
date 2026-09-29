#!/usr/bin/env bash
## Preset for ~500k aggregate concurrent WS clients:
##   4 × 125_000 = 500_000 (≤ ~15000 conn/thread per websocketload worker at ``-t 24``).
##
## Prerequisites (Linux):
##   bash nim_websocketcli/scripts/ws_preflight_500k.sh   # exits non-zero until sysctl + aliases ok
##   sudo bash nim_websocketcli/scripts/ws_scale_linux.sh 253
##   ulimit -n 1048576
##
## Terminal A — io_uring + multithreaded server (same port via SO_REUSEPORT):
##   make ws-echo-bench USOCKETS_BACKEND=io_uring
##   THREADS=$(nproc) PORT=3400 ./benchmark/ws_echo_bench
##
## Terminal B:
##   HOST=127.0.0.1 PORT=3400 PATH_WS=/ WORKERS=4 CHUNK=125000 THREADS=24 \\
##     PARALLEL_FANOUT=2 STAGGER_SEC=25 BATCH_GAP_SEC=45 DURATION=300 \\
##     bash nim_websocketcli/scripts/ws_parallel_load.sh
##
## Or source this file and run the parent script with env already set:

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOST="${HOST:-127.0.0.1}"
export PORT="${PORT:-3400}"
export PATH_WS="${PATH_WS:-/}"
export WORKERS="${WORKERS:-4}"
export CHUNK="${CHUNK:-125000}"
export THREADS="${THREADS:-24}"
export BINDLB="${BINDLB:-253}"
export DURATION="${DURATION:-300}"
export PARALLEL_FANOUT="${PARALLEL_FANOUT:-2}"
export STAGGER_SEC="${STAGGER_SEC:-25}"
export BATCH_GAP_SEC="${BATCH_GAP_SEC:-45}"
exec bash "$SCRIPT_DIR/ws_parallel_load.sh"
