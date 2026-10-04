#!/usr/bin/env bash
# Join a K3s worker node (worker1-3).
# Run as root. Requires K3S_TOKEN from the first master bootstrap; VIP
# defaults to 172.16.10.50, K3S_VERSION is optional.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

VIP="${VIP:-172.16.10.50}"
K3S_TOKEN="${K3S_TOKEN:?K3S_TOKEN is required. Get it from master1: cat /var/lib/rancher/k3s/server/node-token}"
# Standalone fallback, see scripts/01.
K3S_VERSION="${K3S_VERSION:-v1.32.3+k3s1}"

require_root

step_header 1 "Installing node prerequisites"
install_node_prerequisites

step_header 2 "Joining K3s cluster as worker via ${VIP}:6443"
# Agents take no --disable flags; the servers (01/02) disable ServiceLB.
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  K3S_URL="https://${VIP}:6443" \
  K3S_TOKEN="${K3S_TOKEN}" \
  sh -

log "Worker node joined successfully"
log "Verify from master: kubectl get nodes"
