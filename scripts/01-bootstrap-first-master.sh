#!/usr/bin/env bash
# Bootstrap the first control plane and hand the cluster to Argo CD. Run as
# root on that node only. Does what Argo CD can't: kube-vip, K3s init,
# platform/, random secrets, Argo CD + root app. Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

VIP="${VIP:-172.16.10.50}"
# Standalone fallback (same in 02/03); deploy.sh passes k3s_version from
# terraform/variables.tf. Keep the defaults in sync.
K3S_VERSION="${K3S_VERSION:-v1.32.3+k3s1}"

MANIFESTS_DIR="${SCRIPT_DIR}/.."
STATIC_POD_DIR="/var/lib/rancher/k3s/agent/pod-manifests"
KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
export KUBECONFIG

require_root

step_header 1 "Placing kube-vip static pod"
# The template pins eth0/172.16.10.50; rewrite for this node's actual uplink
# (cloud images name it ens18/enp*) and the configured VIP.
DEFAULT_IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
VIP_INTERFACE="${VIP_INTERFACE:-${DEFAULT_IFACE:-eth0}}"
mkdir -p "${STATIC_POD_DIR}"
sed -e "s|value: eth0|value: ${VIP_INTERFACE}|" \
    -e "s|value: \"172.16.10.50\"|value: \"${VIP}\"|" \
  "${MANIFESTS_DIR}/platform/system/kube-vip.yaml" > "${STATIC_POD_DIR}/kube-vip.yaml"
log "kube-vip static pod placed (interface ${VIP_INTERFACE}, VIP ${VIP})"

step_header 2 "Installing K3s ${K3S_VERSION} as first control plane"
# CIDRs are the K3s defaults, pinned because apps/gitea/values.yaml
# (REVERSE_PROXY_TRUSTED_PROXIES) depends on the pod CIDR. Fixed at cluster
# init; every server must pass the same values (02-join-control-plane.sh).
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="server \
    --cluster-init \
    --cluster-cidr 10.42.0.0/16 \
    --service-cidr 10.43.0.0/16 \
    --tls-san ${VIP} \
    --disable traefik \
    --disable servicelb \
    --secrets-encryption \
    --write-kubeconfig-mode 600" \
  sh -

step_header 3 "Waiting for node to become Ready"
until kubectl get nodes 2>/dev/null | grep -E "Ready\\s" | grep -v "NotReady" | grep -q "."; do
  sleep 5
done
log "Node is Ready"

# The first apply may fail partially: IPAddressPool/L2Advertisement need
# MetalLB's webhook, which isn't up yet. Wait for it, then re-apply.
step_header 4 "Deploying network foundation (platform/)"
kubectl apply -k "${MANIFESTS_DIR}/platform" || \
  log "First pass incomplete (MetalLB webhook not ready) - re-applying after rollout"
kubectl rollout status deployment/controller -n metallb-system --timeout=180s
kubectl apply -k "${MANIFESTS_DIR}/platform"
log "MetalLB + CoreDNS override applied from platform/"

# Created once, never overwritten. None need to survive a rebuild (backups
# are --no-owner dumps). The runner tokens start as placeholders: the
# runner-token-bootstrap Job replaces the registration token once Gitea is
# up; gitea-api-token stays one while KEDA autoscaling is pending.
step_header 5 "Generating bootstrap secrets"
for ns in gitea gitea-runners anubis garage; do
  ensure_namespace "${ns}"
done

# bootstrap_secret <name> <namespace> key=value...
bootstrap_secret() {
  local name="$1" ns="$2" kv args=()
  shift 2
  if kubectl get secret "${name}" -n "${ns}" >/dev/null 2>&1; then
    log "Exists: ${ns}/${name}"
    return 0
  fi
  for kv in "$@"; do
    args+=(--from-literal="${kv}")
  done
  kubectl create secret generic "${name}" -n "${ns}" "${args[@]}" >/dev/null
  log "Created: ${ns}/${name}"
}

bootstrap_secret gitea-admin gitea \
  username=gitea-admin "password=$(openssl rand -hex 24)" email=admin@example.com
# Key names are what the postgresql-ha chart's existingSecret expects.
bootstrap_secret postgresql-ha-credentials gitea \
  "postgres-password=$(openssl rand -hex 24)" "password=$(openssl rand -hex 24)" \
  "repmgr-password=$(openssl rand -hex 24)"
bootstrap_secret postgresql-ha-pgpool-credentials gitea \
  "admin-password=$(openssl rand -hex 24)" "sr-check-password=$(openssl rand -hex 24)"
# Bearer token for Gitea's /metrics, which Traefik would otherwise expose.
bootstrap_secret gitea-metrics-token gitea "token=$(openssl rand -hex 32)"
bootstrap_secret garage-rpc garage "rpc-secret=$(openssl rand -hex 32)"
bootstrap_secret anubis-key anubis "ED25519_PRIVATE_KEY_HEX=$(openssl rand -hex 32)"
for secret in gitea-runner-registration gitea-api-token; do
  bootstrap_secret "${secret}" gitea-runners token=placeholder-update-after-gitea-is-up
done

step_header 6 "Installing Argo CD"
# --server-side: the ApplicationSet CRD exceeds client-side apply's 256 KiB
# annotation limit.
# `|| true`: on a fresh cluster the Certificate/IngressRoute/Middleware objects
# in argocd/install/ fail (no cert-manager/Traefik CRDs until wave 2). The
# "argocd" Application creates them later; real failures still surface in
# the rollout waits below.
apply_kustomization "${MANIFESTS_DIR}/argocd/install" --server-side --force-conflicts || true

log "Waiting for Argo CD to be ready..."
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

step_header 7 "Applying root app-of-apps"
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
echo "AFTER GITEA IS UP: no further manual step. The runner registration token"
echo "mints automatically via the runner-token-bootstrap Job, and Garage"
echo "layout + S3 credentials for Gitea object storage/backups mint"
echo "automatically via the garage-bootstrap Job."
echo ""
echo "Save your token:"
echo "  NODE_TOKEN='${K3S_TOKEN}'"
echo "================================================================================"
