#!/usr/bin/env bash
# Bootstrap the first K3s control-plane node and hand the cluster to Argo CD.
# Run as root on master1 only. Other nodes use 02-join-control-plane.sh / 03-join-worker.sh.
#
# This script does only what Argo CD cannot do for itself:
#   1. Node prerequisites + kube-vip static pod (control-plane HA)
#   2. K3s cluster init
#   3. Network foundation (platform/): MetalLB + IP pool, CoreDNS override.
#      Deliberately outside Argo CD so the cluster's addresses are in place
#      and verifiable before GitOps starts, and so MetalLB can be tuned
#      without self-heal reverting changes.
#   4. Bootstrap secrets (random material that must never live in git)
#   5. Argo CD installation + the root app-of-apps
# Everything else (KEDA, kured, Traefik, cert-manager, Gitea, ...) is
# deployed by Argo CD from the argocd/apps/ Applications.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

VIP="${VIP:-172.16.69.50}"
K3S_VERSION="${K3S_VERSION:-v1.32.3+k3s1}"

MANIFESTS_DIR="${SCRIPT_DIR}/.."
STATIC_POD_DIR="/var/lib/rancher/k3s/agent/pod-manifests"
KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
export KUBECONFIG

require_root

step_header 1 "Installing node prerequisites"
install_node_prerequisites

step_header 2 "Placing kube-vip static pod"
# The template pins eth0/172.16.69.50; rewrite for this node's actual uplink
# (cloud images name it ens18/enp*) and the configured VIP.
DEFAULT_IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
VIP_INTERFACE="${VIP_INTERFACE:-${DEFAULT_IFACE:-eth0}}"
mkdir -p "${STATIC_POD_DIR}"
sed -e "s|value: eth0|value: ${VIP_INTERFACE}|" \
    -e "s|value: \"172.16.69.50\"|value: \"${VIP}\"|" \
  "${MANIFESTS_DIR}/platform/system/kube-vip.yaml" > "${STATIC_POD_DIR}/kube-vip.yaml"
log "kube-vip static pod placed (interface ${VIP_INTERFACE}, VIP ${VIP})"

step_header 3 "Installing K3s ${K3S_VERSION} as first control plane"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="server \
    --cluster-init \
    --tls-san ${VIP} \
    --disable traefik \
    --disable servicelb \
    --secrets-encryption \
    --write-kubeconfig-mode 600" \
  sh -

step_header 4 "Waiting for node to become Ready"
until kubectl get nodes 2>/dev/null | grep -E "Ready\\s" | grep -v "NotReady" | grep -q "."; do
  sleep 5
done
log "Node is Ready"

# Applied directly - not via Argo CD - so the VIPs the whole stack depends on
# exist and can be verified before GitOps takes over. The first apply may fail
# partially (IPAddressPool/L2Advertisement need MetalLB's validating webhook,
# which isn't up yet); wait for the controller, then re-apply.
step_header 5 "Deploying network foundation (platform/)"
kubectl apply -k "${MANIFESTS_DIR}/platform" || \
  log "First pass incomplete (MetalLB webhook not ready) - re-applying after rollout"
kubectl rollout status deployment/controller -n metallb-system --timeout=180s
kubectl apply -k "${MANIFESTS_DIR}/platform"
log "MetalLB + CoreDNS override applied from platform/"

# Argo CD can sync manifests but cannot invent secret material. Generated once
# here and never overwritten; the runner/API tokens start as placeholders
# because they can only be minted against a running Gitea (04-deploy-apps.sh
# step 9).
step_header 6 "Generating bootstrap secrets"
for ns in gitea gitea-runners anubis atlantis; do
  ensure_namespace "${ns}"
done

if ! kubectl get secret gitea-admin -n gitea >/dev/null 2>&1; then
  kubectl create secret generic gitea-admin -n gitea \
    --from-literal=username=gitea-admin \
    --from-literal=password="$(openssl rand -hex 24)" \
    --from-literal=email=admin@example.com
  log "Created: gitea/gitea-admin"
else
  log "Exists: gitea/gitea-admin"
fi

if ! kubectl get secret garage-rpc -n atlantis >/dev/null 2>&1; then
  kubectl create secret generic garage-rpc -n atlantis \
    --from-literal=rpc-secret="$(openssl rand -hex 32)"
  log "Created: atlantis/garage-rpc"
else
  log "Exists: atlantis/garage-rpc"
fi

if ! kubectl get secret anubis-key -n anubis >/dev/null 2>&1; then
  kubectl create secret generic anubis-key -n anubis \
    --from-literal=ED25519_PRIVATE_KEY_HEX="$(openssl rand -hex 32)"
  log "Created: anubis/anubis-key"
else
  log "Exists: anubis/anubis-key"
fi

for secret in gitea-runner-registration gitea-api-token; do
  if ! kubectl get secret "${secret}" -n gitea-runners >/dev/null 2>&1; then
    kubectl create secret generic "${secret}" -n gitea-runners \
      --from-literal=token=placeholder-update-after-gitea-is-up
    log "Created: gitea-runners/${secret} (placeholder)"
  else
    log "Exists: gitea-runners/${secret}"
  fi
done

step_header 7 "Installing Argo CD"
# --server-side: the applicationsets.argoproj.io CRD's schema exceeds the
# 262144-byte cap kubectl's client-side apply enforces on the
# last-applied-configuration annotation.
apply_kustomization "${MANIFESTS_DIR}/argocd/install" --server-side --force-conflicts

log "Waiting for Argo CD to be ready..."
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

step_header 8 "Applying root app-of-apps"
kubectl apply -f "${MANIFESTS_DIR}/argocd/root-app.yaml"
log "Argo CD now reconciles the cluster from git (argocd/apps/)"

K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<not yet created>")

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
echo "ARGO CD:"
echo "  UI:       kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Login:    admin / ${ARGOCD_PASS}"
echo "  Watch:    kubectl get applications -n argocd -w"
echo ""
echo "AFTER GITEA IS UP (runtime credentials Argo CD cannot mint):"
echo "  - Runner registration + KEDA API tokens : scripts/04-deploy-apps.sh step 9"
echo "  - Atlantis VCS secret + Garage layout   : scripts/04-deploy-apps.sh steps 10-12"
echo ""
echo "Save your token:"
echo "  NODE_TOKEN='${K3S_TOKEN}'"
echo "================================================================================"
