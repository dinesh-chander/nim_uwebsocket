#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE_SCRIPT="${ROOT_DIR}/benchmark/run_linux_transport_ceiling.sh"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT_DIR}/benchmark/reports/linux_transport_scale_matrix_${STAMP}"
mkdir -p "${OUT_DIR}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "run_linux_transport_scale_matrix.sh must run on Linux." >&2
  exit 1
fi

BACKENDS="${BACKENDS:-epoll io_uring}"
SCALE_MODES="${SCALE_MODES:-single threaded cluster}"
REPETITIONS="${REPETITIONS:-3}"
PORT_BASE="${PORT_BASE:-4300}"
APP_WORKERS="${APP_WORKERS:-4}"

case "${REPETITIONS}" in
  ''|*[!0-9]*)
    echo "REPETITIONS must be a positive integer" >&2
    exit 1
    ;;
esac
if [[ "${REPETITIONS}" -le 0 ]]; then
  echo "REPETITIONS must be a positive integer" >&2
  exit 1
fi

port="${PORT_BASE}"
failures=0
rows=()

for backend in ${BACKENDS}; do
  for scale in ${SCALE_MODES}; do
    case "${scale}" in
      single|threaded|cluster) ;;
      *)
        echo "unsupported scale mode: ${scale}" >&2
        exit 1
        ;;
    esac
    for rep in $(seq 1 "${REPETITIONS}"); do
      run_stamp="${STAMP}_${backend}_${scale}_${rep}"
      run_out="${OUT_DIR}/${backend}_${scale}_${rep}"
      run_log="${run_out}.log"
      mkdir -p "${run_out}"
      echo "[scale-matrix] backend=${backend} scale=${scale} rep=${rep}"
      if STAMP="${run_stamp}" OUT_DIR="${run_out}" BACKENDS="${backend}" APP_SCALE_MODE="${scale}" APP_WORKERS="${APP_WORKERS}" PORT_BASE="${port}" "${BASE_SCRIPT}" >"${run_log}" 2>&1; then
        summary="${run_out}/${backend}/summary.txt"
        status="ok"
        reason="-"
      else
        summary="${run_out}/${backend}/summary.txt"
        status="failed"
        reason="$(awk -F= '/^reason=/{print $2}' "${summary}" 2>/dev/null | tail -1)"
        [[ -z "${reason}" ]] && reason="see ${run_log}"
        failures=$((failures + 1))
      fi
      rps="$(awk -F= '/^rps=/{print $2}' "${summary}" 2>/dev/null | tail -1)"
      avg="$(awk -F= '/^latency_avg=/{print $2}' "${summary}" 2>/dev/null | tail -1)"
      p50="$(awk -F= '/^p50=/{print $2}' "${summary}" 2>/dev/null | tail -1)"
      p90="$(awk -F= '/^p90=/{print $2}' "${summary}" 2>/dev/null | tail -1)"
      p99="$(awk -F= '/^p99=/{print $2}' "${summary}" 2>/dev/null | tail -1)"
      requests="$(awk -F= '/^requests=/{print $2}' "${summary}" 2>/dev/null | tail -1)"
      [[ -z "${rps}" ]] && rps="n/a"
      [[ -z "${avg}" ]] && avg="n/a"
      [[ -z "${p50}" ]] && p50="n/a"
      [[ -z "${p90}" ]] && p90="n/a"
      [[ -z "${p99}" ]] && p99="n/a"
      [[ -z "${requests}" ]] && requests="n/a"
      rows+=("${backend}|${scale}|${rep}|${status}|${rps}|${avg}|${p50}|${p90}|${p99}|${requests}|${reason}|${run_out}/report.md")
      port=$((port + 1))
    done
  done
done

{
  echo "# Linux Transport Scale Matrix"
  echo
  echo "- timestamp: ${STAMP}"
  echo "- backends: ${BACKENDS}"
  echo "- scale_modes: ${SCALE_MODES}"
  echo "- repetitions: ${REPETITIONS}"
  echo "- app_workers: ${APP_WORKERS}"
  echo "- duration: ${DURATION:-20s}"
  echo "- warmup: ${WARMUP:-3s}"
  echo "- threads: ${THREADS:-8}"
  echo "- connections: ${CONNS:-200}"
  echo
  echo "| backend | scale | rep | status | req/s | avg latency | p50 | p90 | p99 | requests | reason | report |"
  echo "|---|---|---:|---|---:|---:|---:|---:|---:|---:|---|---|"
  for row in "${rows[@]}"; do
    IFS='|' read -r backend scale rep status rps avg p50 p90 p99 requests reason report <<<"${row}"
    echo "| ${backend} | ${scale} | ${rep} | ${status} | ${rps} | ${avg} | ${p50} | ${p90} | ${p99} | ${requests} | ${reason} | ${report} |"
  done
} >"${OUT_DIR}/report.md"

echo "[scale-matrix] report: ${OUT_DIR}/report.md"
cat "${OUT_DIR}/report.md"
if [[ "${failures}" -ne 0 ]]; then
  exit 1
fi
