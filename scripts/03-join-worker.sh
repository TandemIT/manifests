#!/usr/bin/env bash
# Join a K3s worker node (worker1-3).
# Run as root. Requires K3S_TOKEN and VIP from the first master bootstrap.

set -euo pipefail

# Source shared functions library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

# ==============================================================================
# Configuration
# ==============================================================================
VIP="${VIP:-172.16.69.50}"
K3S_TOKEN="${K3S_TOKEN:?K3S_TOKEN is required. Get it from master1: cat /var/lib/rancher/k3s/server/node-token}"
K3S_VERSION="${K3S_VERSION:-v1.32.3+k3s1}"

# ==============================================================================
# Validation
# ==============================================================================
require_root

# ==============================================================================
# Join worker node to cluster
# ==============================================================================
step_header 1 "Joining K3s cluster as worker via ${VIP}:6443"
# Workers install as K3s agents; --disable flags are server-only and are not passed here.
# ServiceLB is disabled cluster-wide by the server nodes (01/02 scripts).
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  K3S_URL="https://${VIP}:6443" \
  K3S_TOKEN="${K3S_TOKEN}" \
  sh -

log "Worker node joined successfully"
log "Verify from master: kubectl get nodes"
