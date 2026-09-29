#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$BENCH_DIR/.." && pwd)"
NIM_VERSION="${NIM_VERSION:-2.2.10}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
PLATFORM_ARGS=()
if [ -n "$DOCKER_PLATFORM" ]; then
  PLATFORM_ARGS=(--platform "$DOCKER_PLATFORM")
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run Linux benchmark on macOS."
  exit 1
fi

docker run --rm \
  "${PLATFORM_ARGS[@]}" \
  -v "$ROOT_DIR":/workspace \
  -w /workspace/benchmark \
  "nimlang/nim:${NIM_VERSION}" \
  bash -lc '
    set -euo pipefail
    apt-get update >/dev/null
    apt-get install -y --no-install-recommends build-essential wrk libsqlite3-dev pkg-config >/dev/null
    ./run_linux_single_process.sh
  '
