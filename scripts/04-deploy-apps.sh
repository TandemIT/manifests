#!/usr/bin/env bash
# Fully automated application deployment.
# Secrets are generated on first run and never overwritten on subsequent runs.

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
# Validation
# ============================================================================
step_header 1 "Validating tooling and cluster access"
require_binary kubectl helm curl python3 openssl
require_cluster

# ============================================================================
# Step 2: Ensure required namespaces exist
# ============================================================================
step_header 2 "Ensuring required namespaces exist"
for ns in traefik cert-manager gitea gitea-runners anubis; do
  ensure_namespace "${ns}"
done

# ============================================================================
# Step 3: Generate secrets
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

if ! kubectl get secret gitea-runner-registration -n gitea-runners >/dev/null 2>&1; then
  kubectl create secret generic gitea-runner-registration -n gitea-runners \
    --from-literal=token=placeholder-update-in-step-8
  log "Created: gitea-runners/gitea-runner-registration (placeholder)"
else
  log "Exists: gitea-runners/gitea-runner-registration"
fi

if ! kubectl get secret gitea-api-token -n gitea-runners >/dev/null 2>&1; then
  kubectl create secret generic gitea-api-token -n gitea-runners \
    --from-literal=token=placeholder-update-in-step-8
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
apply_kustomization "${MANIFESTS_DIR}/apps/cert-manager/base"

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

# ============================================================================
# Step 6: Deploy Gitea
# ============================================================================
step_header 6 "Deploying Gitea"
apply_kustomization "${MANIFESTS_DIR}/apps/gitea"

log "Adding Gitea Helm repository..."
helm_repo_add gitea https://dl.gitea.com/charts/

log "Installing/upgrading Gitea Helm chart..."
GITEA_OIDC_VALUES=()
if [[ "${OIDC_ENABLED}" == "true" ]]; then
  GITEA_OIDC_VALUES=(--values "${MANIFESTS_DIR}/apps/gitea/values-oidc.yaml")
fi
helm_upgrade_install gitea gitea/gitea gitea \
  --version "~12.5" \
  --values "${MANIFESTS_DIR}/apps/gitea/values.yaml" \
  "${GITEA_OIDC_VALUES[@]}" \
  --timeout 15m \
  --wait

# ============================================================================
# Step 7: Wait for critical workloads
# ============================================================================
step_header 7 "Waiting for critical workloads"
log "Waiting for Traefik deployment..."
if kubectl get deployment/traefik -n traefik >/dev/null 2>&1; then
  TRAEFIK_DEPLOYMENT="traefik"
else
  TRAEFIK_DEPLOYMENT=$(kubectl get deployment -n traefik -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
[[ -n "${TRAEFIK_DEPLOYMENT}" ]] || die "No Traefik deployment found in namespace traefik"
kubectl rollout status deployment/"${TRAEFIK_DEPLOYMENT}" -n traefik --timeout=120s
log "Waiting for Gitea PostgreSQL HA StatefulSet..."
# postgresql-ha subchart names the StatefulSet <release>-postgresql-ha-postgresql.
# Discover it by label in case the release name ever changes.
PG_SS=$(kubectl get statefulset -n gitea \
  -l app.kubernetes.io/component=postgresql \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
[[ -n "${PG_SS}" ]] || die "No PostgreSQL StatefulSet found in namespace gitea"
kubectl rollout status statefulset/"${PG_SS}" -n gitea --timeout=300s
log "Waiting for Gitea deployment..."
kubectl rollout status deployment/gitea -n gitea --timeout=180s

# ============================================================================
# Step 8: Bootstrap Gitea runner credentials
# ============================================================================
step_header 8 "Bootstrapping Gitea runner credentials"
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
# Step 9: Deploy Gitea runner infrastructure
# ============================================================================
step_header 9 "Deploying Gitea runner infrastructure"
apply_kustomization "${MANIFESTS_DIR}/apps/gitea-runner"



# ============================================================================
# Step 10: Deploy Anubis
# ============================================================================
step_header 10 "Deploying Anubis"
apply_kustomization "${MANIFESTS_DIR}/apps/anubis"

# ============================================================================
# Deployment complete
# ============================================================================
section_header "Deployment Complete"
echo ""
echo "Runners start at 0 replicas and scale up when jobs are queued."
echo "Verify: kubectl get scaledobject -n gitea-runners"
echo "================================================================================"
