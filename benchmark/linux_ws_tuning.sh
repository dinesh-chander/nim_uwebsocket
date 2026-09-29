#!/usr/bin/env bash
set -euo pipefail

# Safe-by-default Linux websocket tuning helper.
# Dry-run unless --apply is provided.

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
  APPLY=1
fi

declare -a SYSCTLS=(
  "net.core.somaxconn=65535"
  "net.core.netdev_max_backlog=250000"
  "net.ipv4.tcp_max_syn_backlog=65535"
  "net.ipv4.ip_local_port_range=10240 65535"
  "net.ipv4.tcp_tw_reuse=1"
  "net.ipv4.tcp_fin_timeout=15"
  "net.ipv4.tcp_mtu_probing=1"
  "net.ipv4.tcp_rmem=4096 87380 33554432"
  "net.ipv4.tcp_wmem=4096 65536 33554432"
)

echo "WebSocket Linux tuning plan:"
for kv in "${SYSCTLS[@]}"; do
  echo "  - $kv"
done
echo
echo "Recommended limits (manual):"
echo "  - nofile >= 1048576"
echo "  - nproc  >= 65535"
echo

if [[ "$APPLY" -ne 1 ]]; then
  echo "Dry-run mode. Re-run with --apply to apply sysctl settings."
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: --apply requires root privileges." >&2
  exit 1
fi

for kv in "${SYSCTLS[@]}"; do
  sysctl -w "$kv"
done

echo
echo "Applied runtime sysctl values."
echo "Persist by writing them into /etc/sysctl.conf or /etc/sysctl.d/*.conf."
