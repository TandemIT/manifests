#!/usr/bin/env bash
# Fully automated application deployment (script-driven alternative).
# Secrets are generated on first run and never overwritten on subsequent runs.
#
# The primary deployment path is Argo CD: scripts/01-bootstrap-first-master.sh
# installs it and applies the root app-of-apps (argocd/), which deploys
# everything in this repo declaratively. On the GitOps path this script is
# only needed for the runtime pieces Argo CD cannot do:
#   step 9      — mint runner registration + KEDA API tokens against live Gitea
#   steps 10-12 — Atlantis VCS secret, Garage cluster layout, S3 credentials
# Running the whole script against an Argo CD-managed cluster is safe:
# resources it applies are adopted by Argo CD on the next sync.

set -euo pipefail

# Source shared functions library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

# ============================================================================
# Configuration
# ============================================================================
MANIFESTS_DIR="${SCRIPT_DIR}/.."

# Ensure kubectl and helm target the same kubeconfig.
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  elif [[ -f "${HOME}/.kube/config" ]]; then
    export KUBECONFIG="${HOME}/.kube/config"
  fi
fi

verify_kubeconfig
log "Using kubeconfig: ${KUBECONFIG}"

# ============================================================================
# Step 1: Validate tooling and cluster access
# ============================================================================
step_header 1 "Validating tooling and cluster access"
require_binary kubectl helm curl python3 openssl
require_cluster

# ============================================================================
# Step 2: Ensure required namespaces exist
# ============================================================================
step_header 2 "Ensuring required namespaces exist"
for ns in traefik cert-manager gitea gitea-runners anubis atlantis; do
  ensure_namespace "${ns}"
done

# ============================================================================
# Step 3: Generate secrets
# Note: atlantis-vcs is created in Step 10, after Gitea is running, so the
# operator can create the bot account and obtain the API token first.
# ============================================================================
step_header 3 "Generating secrets"

if ! kubectl get secret gitea-admin -n gitea >/dev/null 2>&1; then
  kubectl create secret generic gitea-admin -n gitea \
    --from-literal=username=gitea-admin \
    --from-literal=password="$(openssl rand -hex 24)" \
    --from-literal=email=admin@example.com
  log "Created: gitea/gitea-admin"
else
  log "Exists: gitea/gitea-admin"
fi

# Garage rpc-secret (must exist before Garage starts)
if ! kubectl get secret garage-rpc -n atlantis >/dev/null 2>&1; then
  kubectl create secret generic garage-rpc -n atlantis \
    --from-literal=rpc-secret="$(openssl rand -hex 32)"
  log "Created: atlantis/garage-rpc"
else
  log "Exists: atlantis/garage-rpc"
fi

if ! kubectl get secret gitea-runner-registration -n gitea-runners >/dev/null 2>&1; then
  kubectl create secret generic gitea-runner-registration -n gitea-runners \
    --from-literal=token=placeholder-update-in-step-9
  log "Created: gitea-runners/gitea-runner-registration (placeholder)"
else
  log "Exists: gitea-runners/gitea-runner-registration"
fi

if ! kubectl get secret gitea-api-token -n gitea-runners >/dev/null 2>&1; then
  kubectl create secret generic gitea-api-token -n gitea-runners \
    --from-literal=token=placeholder-update-in-step-9
  log "Created: gitea-runners/gitea-api-token (placeholder)"
else
  log "Exists: gitea-runners/gitea-api-token"
fi

if ! kubectl get secret anubis-key -n anubis >/dev/null 2>&1; then
  kubectl create secret generic anubis-key -n anubis \
    --from-literal=ED25519_PRIVATE_KEY_HEX="$(openssl rand -hex 32)"
  log "Created: anubis/anubis-key"
else
  log "Exists: anubis/anubis-key"
fi

OIDC_ENABLED=false
if kubectl get secret gitea-oidc -n gitea >/dev/null 2>&1; then
  log "Exists: gitea/gitea-oidc"
  OIDC_ENABLED=true
else
  echo ""
  read -rp "  Configure Gitea OIDC login (Authentik)? [y/N]: " OIDC_ANSWER
  if [[ "${OIDC_ANSWER,,}" == "y" ]]; then
    echo "  Discovery URL format: https://auth.open-ict.hu/application/o/<slug>/.well-known/openid-configuration"
    echo ""
    read -rp "  OIDC Client ID:     " OIDC_KEY
    read -rsp "  OIDC Client Secret: " OIDC_SECRET
    echo ""
    read -rp "  Discovery URL:      " OIDC_DISCOVERY_URL
    echo ""
    kubectl create secret generic gitea-oidc -n gitea \
      --from-literal=key="${OIDC_KEY}" \
      --from-literal=secret="${OIDC_SECRET}" \
      --from-literal=discoveryURL="${OIDC_DISCOVERY_URL}"
    log "Created: gitea/gitea-oidc"
    OIDC_ENABLED=true
  else
    log "Skipping OIDC — Gitea will use local authentication only"
  fi
fi

# ============================================================================
# Step 4: Deploy cert-manager
# ============================================================================
step_header 4 "Deploying cert-manager"
apply_kustomization "${MANIFESTS_DIR}/apps/cert-manager"

log "Adding jetstack Helm repository..."
helm_repo_add jetstack https://charts.jetstack.io

# Keep the version in sync with argocd/apps/cert-manager.yaml.
helm_upgrade_install cert-manager jetstack/cert-manager cert-manager \
  --version "v1.15.3" \
  --values "${MANIFESTS_DIR}/apps/cert-manager/values.yaml" \
  --wait

log "Waiting for cert-manager CRDs..."
until kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1; do sleep 2; done
until kubectl get crd issuers.cert-manager.io >/dev/null 2>&1; do sleep 2; done
kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout=120s >/dev/null
kubectl wait --for=condition=Established crd/issuers.cert-manager.io --timeout=120s >/dev/null

log "Waiting for cert-manager webhook to be ready..."
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s >/dev/null
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s >/dev/null

log "Applying cert-manager ClusterIssuers..."
apply_kustomization "${MANIFESTS_DIR}/apps/cert-manager/issuers"

# ============================================================================
# Step 5: Deploy Traefik
# ============================================================================
step_header 5 "Deploying Traefik"
apply_kustomization "${MANIFESTS_DIR}/apps/traefik"

log "Adding Traefik Helm repository..."
helm_repo_add traefik https://traefik.github.io/charts

# Keep the version in sync with argocd/apps/traefik.yaml.
helm_upgrade_install traefik traefik/traefik traefik \
  --version "34.4.1" \
  --values "${MANIFESTS_DIR}/apps/traefik/values.yaml"

log "Waiting for Traefik deployment..."
if kubectl get deployment/traefik -n traefik >/dev/null 2>&1; then
  TRAEFIK_DEPLOYMENT="traefik"
else
  TRAEFIK_DEPLOYMENT=$(kubectl get deployment -n traefik -l app.kubernetes.io/name=traefik \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
[[ -n "${TRAEFIK_DEPLOYMENT}" ]] || die "No Traefik deployment found in namespace traefik"
kubectl rollout status deployment/"${TRAEFIK_DEPLOYMENT}" -n traefik --timeout=120s

# ============================================================================
# Step 6: Deploy Anubis
# Anubis sits between Traefik and each protected backend (reverse proxy mode).
# Deploy before Gitea so the IngressRoute and TLS certificate are ready first.
# ============================================================================
step_header 6 "Deploying Anubis"
apply_kustomization "${MANIFESTS_DIR}/apps/anubis"

# ============================================================================
# Step 7: Deploy Gitea
# Must come before Atlantis — Atlantis connects to Gitea on startup.
# ============================================================================
step_header 7 "Deploying Gitea"
apply_kustomization "${MANIFESTS_DIR}/apps/gitea"

log "Adding Gitea Helm repository..."
helm_repo_add gitea https://dl.gitea.com/charts/

log "Installing/upgrading Gitea Helm chart..."
GITEA_OIDC_VALUES=()
if [[ "${OIDC_ENABLED}" == "true" ]]; then
  GITEA_OIDC_VALUES=(--values "${MANIFESTS_DIR}/apps/gitea/values-oidc.yaml")
fi
helm_upgrade_install gitea gitea/gitea gitea \
  --version "12.6.0" \
  --values "${MANIFESTS_DIR}/apps/gitea/values.yaml" \
  "${GITEA_OIDC_VALUES[@]}" \
  --timeout 15m \
  --wait

# ============================================================================
# Step 8: Wait for Gitea to be fully ready
# ============================================================================
step_header 8 "Waiting for Gitea to be ready"
log "Waiting for Gitea PostgreSQL HA StatefulSet..."
PG_SS=$(kubectl get statefulset -n gitea \
  -l app.kubernetes.io/component=postgresql \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
[[ -n "${PG_SS}" ]] || die "No PostgreSQL StatefulSet found in namespace gitea"
kubectl rollout status statefulset/"${PG_SS}" -n gitea --timeout=300s

log "Waiting for Gitea deployment..."
kubectl rollout status deployment/gitea -n gitea --timeout=180s

# ============================================================================
# Step 9: Bootstrap Gitea runner credentials
# ============================================================================
step_header 9 "Bootstrapping Gitea runner credentials"
ADMIN_USER=$(kubectl get secret gitea-admin -n gitea -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl get secret gitea-admin -n gitea -o jsonpath='{.data.password}' | base64 -d)

log "Starting port-forward to Gitea..."
kubectl port-forward svc/gitea-http -n gitea 13000:3000 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT

log "Waiting for Gitea API..."
until curl -sf "http://localhost:13000/api/healthz" >/dev/null 2>&1; do sleep 3; done

if kubectl get secret gitea-runner-registration -n gitea-runners -o jsonpath='{.data.token}' \
    | base64 -d | grep -q "^placeholder"; then
  REG_TOKEN=$(curl -sf \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "http://localhost:13000/api/v1/admin/runners/registration-token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || echo "")

  if [[ -n "${REG_TOKEN}" ]]; then
    kubectl create secret generic gitea-runner-registration -n gitea-runners \
      --from-literal=token="${REG_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -
    log "Updated: gitea-runners/gitea-runner-registration"
  else
    warn "Could not retrieve runner registration token automatically"
    warn "Get it from Gitea admin panel and run:"
    warn "  kubectl create secret generic gitea-runner-registration \\"
    warn "    -n gitea-runners --from-literal=token=<token> --dry-run=client -o yaml | kubectl apply -f -"
  fi
fi

if kubectl get secret gitea-api-token -n gitea-runners -o jsonpath='{.data.token}' \
    | base64 -d | grep -q "^placeholder"; then
  KEDA_TOKEN=$(curl -sf -X POST \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    -d '{"name":"keda-scaler","scopes":["read:admin"]}' \
    "http://localhost:13000/api/v1/users/${ADMIN_USER}/tokens" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['sha1'])" 2>/dev/null || echo "")

  if [[ -n "${KEDA_TOKEN}" ]]; then
    kubectl create secret generic gitea-api-token -n gitea-runners \
      --from-literal=token="${KEDA_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -
    log "Updated: gitea-runners/gitea-api-token"
  else
    warn "Could not create KEDA API token automatically"
    warn "Create a Gitea PAT with read:admin scope, then run:"
    warn "  kubectl create secret generic gitea-api-token \\"
    warn "    -n gitea-runners --from-literal=token=<token> --dry-run=client -o yaml | kubectl apply -f -"
  fi
fi

kill ${PF_PID} 2>/dev/null || true
trap - EXIT

# ============================================================================
# Step 10: Create Atlantis VCS secret
# Gitea is now running — the operator can log in, create the bot account, and
# generate an API token before this prompt appears.
# ============================================================================
step_header 10 "Configuring Atlantis VCS credentials"

if ! kubectl get secret atlantis-vcs -n atlantis >/dev/null 2>&1; then
  echo ""
  echo "  Gitea is now running. Create a bot user in Gitea, generate an API token"
  echo "  for it, then provide the details below."
  echo ""
  read -rp "  Gitea bot username:    " ATLANTIS_USER
  read -rsp "  Gitea API token:       " ATLANTIS_TOKEN
  echo ""
  read -rp "  Terraform secret:      " TF_VAR_gitea_token
  echo ""
  read -rsp "  Webhook secret:        " ATLANTIS_WEBHOOK_SECRET
  echo ""
  kubectl create secret generic atlantis-vcs -n atlantis \
    --from-literal=username="${ATLANTIS_USER}" \
    --from-literal=token="${ATLANTIS_TOKEN}" \
    --from-literal=webhook-secret="${ATLANTIS_WEBHOOK_SECRET}" \
    --from-literal=tf-token="${TF_VAR_gitea_token}"
  log "Created: atlantis/atlantis-vcs"
else
  log "Exists: atlantis/atlantis-vcs"
fi

# ============================================================================
# Step 11: Deploy Atlantis
# Gitea is running and atlantis-vcs is populated — Atlantis can reach Gitea.
# ============================================================================
step_header 11 "Deploying Atlantis"
apply_kustomization "${MANIFESTS_DIR}/apps/atlantis"

# ============================================================================
# Step 12: Bootstrap Garage S3 credentials
# Garage must be running before we can create an access key, so this step
# comes after the Atlantis kustomization (which also deploys Garage).
# The Atlantis pod starts with CreateContainerConfigError until this secret
# exists; once created, Kubernetes retries the pod automatically.
# ============================================================================
step_header 12 "Bootstrapping Garage S3 credentials"

log "Waiting for Garage to be ready..."
kubectl rollout status statefulset/garage -n atlantis --timeout=300s

# Connect the replicas into one Garage cluster.
# Idempotent: "node connect" is a no-op for peers that are already known.
GARAGE_REPLICAS=3
for i in $(seq 1 $((GARAGE_REPLICAS - 1))); do
  PEER_ID=$(kubectl exec -n atlantis "garage-${i}" -- /garage -c /etc/garage/garage.toml node id -q)
  kubectl exec -n atlantis garage-0 -- /garage -c /etc/garage/garage.toml node connect "${PEER_ID}"
done

# Assign a layout role to every node that lacks one (fresh cluster: all three).
# 50G per node with replication_factor=3 gives ~50G usable capacity.
if kubectl exec -n atlantis garage-0 -- /garage -c /etc/garage/garage.toml status 2>/dev/null \
    | grep -q "NO ROLE ASSIGNED"; then
  for NODE_ID in $(kubectl exec -n atlantis garage-0 -- /garage -c /etc/garage/garage.toml status 2>/dev/null \
      | awk '/NO ROLE ASSIGNED/{print $1}'); do
    kubectl exec -n atlantis garage-0 -- /garage -c /etc/garage/garage.toml \
      layout assign -z dc1 -c 50G "${NODE_ID}"
  done
  # Next layout version is always current + 1 (fresh cluster: 0 + 1).
  CUR_LAYOUT=$(kubectl exec -n atlantis garage-0 -- /garage -c /etc/garage/garage.toml layout show 2>/dev/null \
    | awk '/layout version:/{v=$NF} END{print v+0}')
  kubectl exec -n atlantis garage-0 -- /garage -c /etc/garage/garage.toml \
    layout apply --version $((CUR_LAYOUT + 1))
  log "Applied Garage cluster layout"
else
  log "Exists: Garage cluster layout"
fi

if ! kubectl get secret garage-s3-credentials -n atlantis >/dev/null 2>&1; then
  KEY_INFO=$(kubectl exec -n atlantis garage-0 -- /garage -c /etc/garage/garage.toml \
    key create atlantis-tf 2>/dev/null)
  ACCESS_KEY=$(echo "${KEY_INFO}" | awk '/^Key ID:/{print $3}')
  SECRET_KEY=$(echo "${KEY_INFO}" | awk '/^Secret key:/{print $3}')

  kubectl exec -n atlantis garage-0 -- /garage -c /etc/garage/garage.toml \
    bucket create terraform-state 2>/dev/null || true
  kubectl exec -n atlantis garage-0 -- /garage -c /etc/garage/garage.toml \
    bucket allow --read --write --owner terraform-state --key "${ACCESS_KEY}"

  kubectl create secret generic garage-s3-credentials -n atlantis \
    --from-literal=access-key-id="${ACCESS_KEY}" \
    --from-literal=secret-access-key="${SECRET_KEY}"
  log "Created: atlantis/garage-s3-credentials"
else
  log "Exists: atlantis/garage-s3-credentials"
fi

log "Waiting for Atlantis to be ready..."
kubectl wait pod/atlantis-0 -n atlantis --for=condition=Ready --timeout=120s

# ============================================================================
# Step 13: Deploy Gitea runner infrastructure
# ============================================================================
step_header 13 "Deploying Gitea runner infrastructure"
apply_kustomization "${MANIFESTS_DIR}/apps/gitea-runner"

# ============================================================================
# Deployment complete
# ============================================================================
section_header "Deployment Complete"
echo ""
echo "Runners start at 0 replicas and scale up when jobs are queued."
echo "Verify: kubectl get scaledobject -n gitea-runners"
echo "================================================================================"
