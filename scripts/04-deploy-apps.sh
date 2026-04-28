#!/usr/bin/env bash
# Fully automated application deployment.
# Secrets are generated on first run and never overwritten on subsequent runs.

set -euo pipefail

# Source shared functions library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

# ============================================================================
# Configuration & Validation
# ============================================================================
MANIFESTS_DIR="${SCRIPT_DIR}/.."

if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  elif [[ -f "${HOME}/.kube/config" ]]; then
    export KUBECONFIG="${HOME}/.kube/config"
  fi
fi

verify_kubeconfig
log "Using kubeconfig: ${KUBECONFIG}"

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
# Step 3: Generate Non-Interactive Secrets
# ============================================================================
step_header 3 "Generating initial secrets"

# Gitea Admin Credentials
if ! kubectl get secret gitea-admin -n gitea >/dev/null 2>&1; then
  kubectl create secret generic gitea-admin -n gitea \
    --from-literal=username=gitea-admin \
    --from-literal=password="$(openssl rand -hex 24)" \
    --from-literal=email=admin@example.com
  log "Created: gitea/gitea-admin"
else
  log "Exists: gitea/gitea-admin"
fi

# Garage rpc-secret (Required for Garage cluster formation)
if ! kubectl get secret garage-rpc -n atlantis >/dev/null 2>&1; then
  kubectl create secret generic garage-rpc -n atlantis \
    --from-literal=rpc-secret="$(openssl rand -hex 32)"
  log "Created: atlantis/garage-rpc"
else
  log "Exists: atlantis/garage-rpc"
fi

# Anubis Private Key
if ! kubectl get secret anubis-key -n anubis >/dev/null 2>&1; then
  kubectl create secret generic anubis-key -n anubis \
    --from-literal=ED25519_PRIVATE_KEY_HEX="$(openssl rand -hex 32)"
  log "Created: anubis/anubis-key"
else
  log "Exists: anubis/anubis-key"
fi

# Placeholder secrets for Gitea Runners (Updated in Step 11)
for secret in gitea-runner-registration gitea-api-token; do
  if ! kubectl get secret "$secret" -n gitea-runners >/dev/null 2>&1; then
    kubectl create secret generic "$secret" -n gitea-runners \
      --from-literal=token=placeholder-update-in-step-11
    log "Created: gitea-runners/$secret (placeholder)"
  fi
done

# ============================================================================
# Step 4: Deploy Core Infrastructure (Cert-Manager & Traefik)
# ============================================================================
step_header 4 "Deploying cert-manager"
apply_kustomization "${MANIFESTS_DIR}/apps/cert-manager/base"

log "Waiting for cert-manager CRDs..."
until kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1; do sleep 2; done
kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout=120s >/dev/null

log "Waiting for cert-manager webhook..."
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s >/dev/null

log "Applying cert-manager ClusterIssuers..."
apply_kustomization "${MANIFESTS_DIR}/apps/cert-manager/issuers"

step_header 5 "Deploying Traefik"
apply_kustomization "${MANIFESTS_DIR}/apps/traefik"

# ============================================================================
# Step 6: Deploy Garage (Storage Layer)
# ============================================================================
step_header 6 "Deploying Garage"
apply_kustomization "${MANIFESTS_DIR}/apps/garage"

# Bootstrap S3 credentials immediately so Atlantis can use them
if ! kubectl get secret garage-s3-credentials -n atlantis >/dev/null 2>&1; then
  log "Waiting for Garage pod to be ready for bootstrapping..."
  kubectl rollout status statefulset/garage -n atlantis --timeout=300s || die "Garage pod failed to start"
  
  GARAGE_POD=$(kubectl get pod -n atlantis -l app.kubernetes.io/name=garage -o jsonpath='{.items[0].metadata.name}')
  
  log "Configuring Garage layout and creating S3 keys..."
  NODE_ID=$(kubectl -n atlantis exec "$GARAGE_POD" -- garage node id | awk '{print $1}')
  kubectl -n atlantis exec "$GARAGE_POD" -- garage layout assign "$NODE_ID" -z dc1 -c 1
  kubectl -n atlantis exec "$GARAGE_POD" -- garage layout apply --version 1
  kubectl -n atlantis exec "$GARAGE_POD" -- garage bucket create terraform-state
  
  CREDS=$(kubectl -n atlantis exec "$GARAGE_POD" -- garage key create atlantis)
  ACCESS_KEY=$(echo "$CREDS" | grep 'access key:' | awk '{print $3}')
  SECRET_KEY=$(echo "$CREDS" | grep 'secret key:' | awk '{print $3}')
  
  kubectl -n atlantis exec "$GARAGE_POD" -- garage bucket allow terraform-state --read --write --key atlantis
  
  kubectl create secret generic garage-s3-credentials -n atlantis \
    --from-literal=access-key-id="$ACCESS_KEY" \
    --from-literal=secret-access-key="$SECRET_KEY"
  log "Created: atlantis/garage-s3-credentials"
else
  log "Exists: atlantis/garage-s3-credentials"
fi

# ============================================================================
# Step 7: Deploy Anubis & Atlantis
# ============================================================================
step_header 7 "Deploying Anubis & Atlantis"

# Interactive VCS Secret for Atlantis
if ! kubectl get secret atlantis-vcs -n atlantis >/dev/null 2>&1; then
  echo -e "\n--- Atlantis Configuration ---"
  read -rp "  Gitea bot username:     " ATLANTIS_USER
  read -rsp "  Gitea API token:        " ATLANTIS_TOKEN
  echo ""
  read -rsp "  Webhook secret:         " ATLANTIS_WEBHOOK_SECRET
  echo -e "\n"
  kubectl create secret generic atlantis-vcs -n atlantis \
    --from-literal=username="${ATLANTIS_USER}" \
    --from-literal=token="${ATLANTIS_TOKEN}" \
    --from-literal=webhook-secret="${ATLANTIS_WEBHOOK_SECRET}"
fi

apply_kustomization "${MANIFESTS_DIR}/apps/anubis"
apply_kustomization "${MANIFESTS_DIR}/apps/atlantis"

# ============================================================================
# Step 8: Deploy Gitea
# ============================================================================
step_header 8 "Deploying Gitea"

OIDC_ENABLED=false
if kubectl get secret gitea-oidc -n gitea >/dev/null 2>&1; then
  OIDC_ENABLED=true
else
  read -rp "  Configure Gitea OIDC (Authentik)? [y/N]: " OIDC_ANSWER
  if [[ "${OIDC_ANSWER,,}" == "y" ]]; then
    read -rp "  OIDC Client ID:      " OIDC_KEY
    read -rsp "  OIDC Client Secret:  " OIDC_SECRET; echo ""
    read -rp "  Discovery URL:       " OIDC_DISCOVERY_URL
    kubectl create secret generic gitea-oidc -n gitea \
      --from-literal=key="${OIDC_KEY}" \
      --from-literal=secret="${OIDC_SECRET}" \
      --from-literal=discoveryURL="${OIDC_DISCOVERY_URL}"
    OIDC_ENABLED=true
  fi
fi

apply_kustomization "${MANIFESTS_DIR}/apps/gitea"
helm_repo_add gitea https://dl.gitea.com/charts/

GITEA_OIDC_VALUES=()
[[ "${OIDC_ENABLED}" == "true" ]] && GITEA_OIDC_VALUES=(--values "${MANIFESTS_DIR}/apps/gitea/values-oidc.yaml")

helm_upgrade_install gitea gitea/gitea gitea \
  --version "~12.5" \
  --values "${MANIFESTS_DIR}/apps/gitea/values.yaml" \
  "${GITEA_OIDC_VALUES[@]}" \
  --timeout 15m --wait

# ============================================================================
# Step 9: Wait for Readiness
# ============================================================================
step_header 9 "Waiting for critical workloads"
kubectl rollout status deployment/gitea -n gitea --timeout=180s

# ============================================================================
# Step 10: Bootstrap Gitea Runner Credentials
# ============================================================================
step_header 10 "Bootstrapping Gitea runner credentials"
ADMIN_USER=$(kubectl get secret gitea-admin -n gitea -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl get secret gitea-admin -n gitea -o jsonpath='{.data.password}' | base64 -d)

kubectl port-forward svc/gitea-http -n gitea 13000:3000 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT

log "Waiting for Gitea API..."
until curl -sf "http://localhost:13000/api/healthz" >/dev/null 2>&1; do sleep 3; done

# Update Registration Token
if kubectl get secret gitea-runner-registration -n gitea-runners -o jsonpath='{.data.token}' | base64 -d | grep -q "^placeholder"; then
  REG_TOKEN=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "http://localhost:13000/api/v1/admin/runners/registration-token" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || echo "")
  if [[ -n "${REG_TOKEN}" ]]; then
    kubectl create secret generic gitea-runner-registration -n gitea-runners --from-literal=token="${REG_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
  fi
fi

# Update API Token (KEDA)
if kubectl get secret gitea-api-token -n gitea-runners -o jsonpath='{.data.token}' | base64 -d | grep -q "^placeholder"; then
  KEDA_TOKEN=$(curl -sf -X POST -u "${ADMIN_USER}:${ADMIN_PASS}" -H "Content-Type: application/json" -d '{"name":"keda-scaler","scopes":["read:admin"]}' "http://localhost:13000/api/v1/users/${ADMIN_USER}/tokens" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha1'])" 2>/dev/null || echo "")
  if [[ -n "${KEDA_TOKEN}" ]]; then
    kubectl create secret generic gitea-api-token -n gitea-runners --from-literal=token="${KEDA_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
  fi
fi

kill ${PF_PID} 2>/dev/null || true
trap - EXIT

# ============================================================================
# Step 11: Deploy Gitea runner infrastructure
# ============================================================================
step_header 11 "Deploying Gitea runner infrastructure"
apply_kustomization "${MANIFESTS_DIR}/apps/gitea-runner"

section_header "Deployment Complete"