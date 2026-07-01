#!/usr/bin/env bash
# Discover each E2E VM's NAT eth0 IP (the AWX-reachable address) and write the
# E2E host_vars so the inventory's ansible_host resolves to it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/.e2e-state/e2e_ssh_key"
cd "$ROOT/vagrant/e2e_smoke"
get_ip(){ VAGRANT_DEFAULT_PROVIDER=vmware_desktop vagrant ssh "$1" -c \
  "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]' | tail -1; }
ES_IP=$(get_ip fpc-e2e-es-01); REC_IP=$(get_ip fpc-e2e-rec-01)
echo "ES=$ES_IP REC=$REC_IP"
[ -n "$ES_IP" ] && [ -n "$REC_IP" ] || { echo "ERROR: could not discover both IPs"; exit 1; }
HV="$ROOT/inventories/e2e/host_vars"; mkdir -p "$HV"
cat > "$HV/fpc-e2e-es-01.yml" <<EOF
---
physical_host: fpc-e2e-es-01
management_ip: "${ES_IP}"
host_cpu_cores: 4
es_data_devices: []
EOF
cat > "$HV/fpc-e2e-rec-01.yml" <<EOF
---
physical_host: fpc-e2e-rec-01
management_ip: "${REC_IP}"
host_cpu_cores: 4
EOF
printf 'ES_IP=%s\nREC_IP=%s\n' "$ES_IP" "$REC_IP" > "$ROOT/.e2e-state/vm_ips.env"
chmod 600 "$ROOT/.e2e-state/vm_ips.env"
echo "host_vars written."
