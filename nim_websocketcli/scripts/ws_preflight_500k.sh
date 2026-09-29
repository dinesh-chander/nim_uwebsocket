#!/usr/bin/env bash
## Exit 0 only if this box looks ready for ~500k outgoing WS connections to localhost.
## Requires many loopback aliases + wide ephemeral port range + high FD ulimit.

set -euo pipefail

fail() { printf 'preflight: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Linux ]] || fail "Linux only for this checklist."

need=$((500000))
have_ulimit="$(ulimit -n 2>/dev/null || echo 0)"
if [[ "${have_ulimit}" =~ ^[0-9]+$ ]] && [[ "${have_ulimit}" -lt "${need}" ]]; then
  fail "ulimit -n is ${have_ulimit}; need >= ${need} (try: ulimit -n 1048576)."
fi

aliases="$(ip -4 addr show dev lo 2>/dev/null | grep -oE '127\.0\.0\.[0-9]+' | wc -l)"
if [[ "${aliases}" -lt 64 ]]; then
  fail "Only ${aliases} IPv4 addr(s) on lo (need many e.g. 127.0.0.2 …). Run:\n  sudo bash nim_websocketcli/scripts/ws_scale_linux.sh 253"
fi

range="$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || true)"
read -r low high <<<"${range}"
span=$((high - low))
if [[ "${span}" -lt 50000 ]]; then
  fail "ip_local_port_range span too small (${range}); run sudo nim_websocketcli/scripts/ws_scale_linux.sh"
fi

echo "preflight: OK (aliases=${aliases}, ulimit=${have_ulimit}, ports=${range})"
