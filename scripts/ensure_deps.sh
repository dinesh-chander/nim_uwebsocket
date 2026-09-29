#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_vendor_dirs=(
  "${ROOT_DIR}/vendor/zippy/src"
  "${ROOT_DIR}/vendor/brotli/src"
  "${ROOT_DIR}/vendor/nim_zstd"
  "${ROOT_DIR}/vendor/nim_libdeflate_gzip/src"
  "${ROOT_DIR}/vendor/malebolgia/src"
  "${ROOT_DIR}/vendor/jsony/src"
  "${ROOT_DIR}/vendor/checksums"
)

missing_vendor=0
for dir in "${required_vendor_dirs[@]}"; do
  if [[ ! -d "${dir}" ]]; then
    missing_vendor=1
    break
  fi
done

if [[ "${missing_vendor}" == "0" ]]; then
  exit 0
fi

if ! command -v nimble >/dev/null 2>&1; then
  echo "vendor dependencies are missing and nimble is not available" >&2
  exit 1
fi

nimble install -y \
  zippy@0.10.19 \
  brotli@0.2.0 \
  zstd@0.9.0 \
  libdeflate_gzip@0.6.0 \
  malebolgia@1.3.2 \
  jsony@1.1.6 \
  checksums@0.2.2
