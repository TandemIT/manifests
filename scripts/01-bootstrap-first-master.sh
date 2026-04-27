#!/usr/bin/env bash
# Bootstrap the first K3s control-plane node.
# Run as root on master1 only. Other nodes use 02-join-control-plane.sh / 03-join-worker.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

VIP="${VIP:-172.16.69.50}"
K3S_VERSION="${K3S_VERSION:-v1.32.3+k3s1}"
KEDA_VERSION="${KEDA_VERSION:-2.15.1}"
METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"

MANIFESTS_DIR="${SCRIPT_DIR}/.."
STATIC_POD_DIR="/var/lib/rancher/k3s/agent/pod-manifests"
KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
export KUBECONFIG

require_root

step_header 1 "Installing node prerequisites"
install_node_prerequisites

step_header 2 "Placing kube-vip static pod"
mkdir -p "${STATIC_POD_DIR}"
cp "${MANIFESTS_DIR}/platform/system/kube-vip.yaml" "${STATIC_POD_DIR}/kube-vip.yaml"
log "kube-vip static pod placed at ${STATIC_POD_DIR}/kube-vip.yaml"

step_header 3 "Installing K3s ${K3S_VERSION} as first control plane"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="server \
    --cluster-init \
    --tls-san ${VIP} \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode 600" \
  sh -

step_header 4 "Waiting for node to become Ready"
until kubectl get nodes 2>/dev/null | grep -E "Ready\\s" | grep -v "NotReady" | grep -q "."; do
  sleep 5
done
log "Node is Ready"

step_header 5 "Applying RBAC"
apply_kustomization "${MANIFESTS_DIR}/platform/rbac/"

step_header 6 "Installing kured"
apply_kustomization "${MANIFESTS_DIR}/platform/system/"

# MetalLB must be applied after CNI is ready and before applications request LoadBalancer IPs.
# The controller deployment is installed from the official release manifest; the IP pool
# configuration (IPAddressPool + L2Advertisement) lives in platform/metallb/.
step_header 7 "Installing MetalLB ${METALLB_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
log "Waiting for MetalLB controller..."
kubectl rollout status deployment/controller -n metallb-system --timeout=120s
log "Applying MetalLB IP pool configuration"
kubectl apply -k "${MANIFESTS_DIR}/platform/metallb/"

# server-side apply required: scaledjobs CRD exceeds the 262144-byte annotation limit for client-side apply
step_header 8 "Installing KEDA ${KEDA_VERSION}"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}.yaml"
log "Waiting for KEDA operator..."
kubectl rollout status deployment/keda-operator -n keda --timeout=180s

K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)

log "Bootstrap complete!"
section_header "Bootstrap Summary"
echo ""
echo "Cluster VIP   : https://${VIP}:6443"
echo "Kubeconfig    : ${KUBECONFIG}"
echo ""
echo "JOIN ADDITIONAL CONTROL PLANE NODES (master2, master3):"
echo "  sudo K3S_TOKEN='${K3S_TOKEN}' VIP='${VIP}' bash scripts/02-join-control-plane.sh"
echo ""
echo "JOIN WORKER NODES (worker1-3):"
echo "  sudo K3S_TOKEN='${K3S_TOKEN}' VIP='${VIP}' bash scripts/03-join-worker.sh"
echo ""
echo "Save your token:"
echo "  NODE_TOKEN='${K3S_TOKEN}'"
echo ""
echo "For custom scripts:"
echo " export K3S_TOKEN='${K3S_TOKEN}'; export VIP='${VIP}'"
echo "================================================================================"
