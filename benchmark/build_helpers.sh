#!/usr/bin/env bash
set -euo pipefail

bench_init_cold_build() {
  BENCH_ROOT_DIR="$1"
  BENCH_OUT_DIR="$2"
  BENCH_BUILD_DIR="${BENCH_OUT_DIR}/build"
  BENCH_NIMCACHE_DIR="${BENCH_BUILD_DIR}/nimcache"
  mkdir -p "${BENCH_BUILD_DIR}" "${BENCH_NIMCACHE_DIR}"
}

bench_nimcache_path() {
  printf '%s\n' "${BENCH_NIMCACHE_DIR}/$1"
}

bench_rebuild_usockets() {
  local log_path="${1:-${BENCH_BUILD_DIR}/build_usockets.log}"
  local backend
  backend="$(bench_usockets_backend)"
  echo "[build] usockets"
  make -C "${BENCH_ROOT_DIR}" usockets USOCKETS_BACKEND="${backend}" >"${log_path}" 2>&1
}

bench_usockets_backend() {
  if [[ -n "${USOCKETS_BACKEND:-}" ]]; then
    printf '%s\n' "${USOCKETS_BACKEND}"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) printf '%s\n' "gcd" ;;
    Linux) printf '%s\n' "epoll" ;;
    *) printf '%s\n' "" ;;
  esac
}

bench_backend_nim_flags() {
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "-d:LIBUS_USE_GCD"
      ;;
    Linux)
      if [[ "$(bench_usockets_backend)" == "io_uring" ]]; then
        printf '%s\n' "-d:LIBUS_USE_IO_URING"
      fi
      ;;
  esac
}

bench_platform_cflags() {
  case "$(uname -s)" in
    Linux)
      printf '%s\n' "-D_GNU_SOURCE -ftls-model=local-exec"
      ;;
  esac
}

bench_platform_link_flags() {
  local usockets_lib="${1:-${BENCH_ROOT_DIR}/nim_usockets/usockets/uSockets.a}"
  local flags="${usockets_lib}"
  case "$(uname -s)" in
    Darwin)
      flags="${flags} -framework CoreFoundation"
      ;;
	    Linux)
	      flags="${flags} -lpthread -ldl"
	      if [[ "$(bench_usockets_backend)" == "io_uring" ]]; then
	        flags="${flags} -luring"
	      fi
	      ;;
	  esac
	  printf '%s\n' "${flags}"
}

bench_native_cflags() {
  if [[ "${NATIVE_OPT:-1}" != "1" ]]; then
    return 0
  fi

  case "$(uname -m)" in
    x86_64|amd64)
      printf '%s\n' "-march=native -mtune=native"
      ;;
    arm64|aarch64)
      printf '%s\n' "-mcpu=native"
      ;;
  esac
}

bench_set_common_paths() {
  local root="${1:-${BENCH_ROOT_DIR}}"
  BENCH_COMMON_PATHS=(
    --path:"${root}/nim_utils/src"
    --path:"${root}/nim_usockets/src"
    --path:"${root}/nim_fasthttpclient/src"
    --path:"${root}/nim_express/src"
    --path:"${root}/vendor/zippy/src"
    --path:"${root}/vendor/brotli/src"
    --path:"${root}/vendor/nim_zstd"
    --path:"${root}/vendor/nim_libdeflate_gzip/src"
    --path:"${root}/vendor/malebolgia/src"
    --path:"${root}/vendor/jsony/src"
    --path:"${root}/vendor/checksums"
  )
}

bench_common_paths_shell() {
  bench_set_common_paths "$@"
  printf ' %q' "${BENCH_COMMON_PATHS[@]}"
}

bench_make() {
  local cache_name="$1"
  shift
  local cache_dir
  local backend_flags
  cache_dir="$(bench_nimcache_path "${cache_name}")"
  backend_flags="$(bench_backend_nim_flags)"
  mkdir -p "${cache_dir}"
  make -C "${BENCH_ROOT_DIR}" "$@" NIM_EXTRA_FLAGS="${backend_flags} -f --nimcache:${cache_dir}"
}

bench_nim() {
  local cache_name="$1"
  shift
  local cache_dir
  local nim_subcmd="$1"
  shift
  cache_dir="$(bench_nimcache_path "${cache_name}")"
  mkdir -p "${cache_dir}"
  nim "${nim_subcmd}" -f --cc:clang "--nimcache:${cache_dir}" "$@"
}
