#!/usr/bin/env bash
# Join an additional K3s control plane node (master2, master3).
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

MANIFESTS_DIR="${SCRIPT_DIR}/.."
STATIC_POD_DIR="/var/lib/rancher/k3s/agent/pod-manifests"

# ==============================================================================
# Validation
# ==============================================================================
require_root

# ==============================================================================
# Step 1: Install node prerequisites
# ==============================================================================
step_header 1 "Installing node prerequisites"
install_node_prerequisites

# ==============================================================================
# Step 2: Place kube-vip static pod
# ==============================================================================
step_header 2 "Placing kube-vip static pod"
# Same interface/VIP rewrite as 01-bootstrap-first-master.sh.
DEFAULT_IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
VIP_INTERFACE="${VIP_INTERFACE:-${DEFAULT_IFACE:-eth0}}"
mkdir -p "${STATIC_POD_DIR}"
sed -e "s|value: eth0|value: ${VIP_INTERFACE}|" \
    -e "s|value: \"172.16.69.50\"|value: \"${VIP}\"|" \
  "${MANIFESTS_DIR}/platform/system/kube-vip.yaml" > "${STATIC_POD_DIR}/kube-vip.yaml"
log "kube-vip static pod placed (interface ${VIP_INTERFACE}, VIP ${VIP})"

# ==============================================================================
# Step 3: Join as additional control plane node
# ==============================================================================
step_header 3 "Joining K3s cluster as control plane via ${VIP}:6443"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  K3S_TOKEN="${K3S_TOKEN}" \
  INSTALL_K3S_EXEC="server \
    --server https://${VIP}:6443 \
    --tls-san ${VIP} \
    --disable traefik \
    --disable servicelb \
    --secrets-encryption \
    --write-kubeconfig-mode 600" \
  sh -

log "Control plane node joined successfully"
log "Verify with: kubectl get nodes"
