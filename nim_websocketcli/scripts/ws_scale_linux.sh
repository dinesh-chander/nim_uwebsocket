#!/usr/bin/env bash
# Tune sysctl and add IPv4 loopback aliases so many outbound TCP connections to one
# 127.0.0.1:port do not exhaust ephemeral ports (~28k per src/dst quad).
#
# Usage:
#   sudo ./ws_scale_linux.sh [NUM_ALIASES]
# Default NUM_ALIASES=64 → 127.0.0.2 … 127.0.0.65
#
# Pair with:
#   websocketload ... --bind-loopbacks NUM_ALIASES

set -euo pipefail

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  echo "Usage: sudo $0 [NUM_ALIASES default 64]"
  exit 0
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ws_scale_linux.sh must run on Linux."
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

N="${1:-64}"
if [[ "$N" -lt 1 ]] || [[ "$N" -gt 253 ]]; then
  echo "NUM_ALIASES must be 1..253"
  exit 1
fi

sysctl -w net.ipv4.ip_local_port_range="1024 65535" 2>/dev/null || true
sysctl -w net.core.somaxconn=65535 2>/dev/null || true
sysctl -w fs.file-max=2097152 2>/dev/null || true
sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null || true

for ((i = 2; i <= N + 1; i++)); do
  ip addr add "127.0.0.$i/32" dev lo 2>/dev/null || true
done

echo "Added 127.0.0.2 … 127.0.0.$((N + 1)) on lo (ignored if duplicate)."
echo "Raise shell ulimit if needed: ulimit -n 1048576"
