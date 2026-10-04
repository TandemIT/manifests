#!/usr/bin/env bash
# Deletes the cert-manager, traefik, anubis, gitea, gitea-runners and garage
# namespaces (PVCs included) plus Traefik/cert-manager cluster-scoped leftovers.
# Argo CD and its Applications are untouched, so Argo CD recreates the apps.
# The scripts/01 and scripts/06 secrets are saved first and restored at the
# end; the runner tokens go back as placeholders, and the Garage S3 keys are
# not kept, because the fresh Gitea and Garage get theirs from the bootstrap Jobs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

APP_NAMESPACES=(cert-manager traefik anubis gitea gitea-runners garage)
TRAEFIK_CLUSTER_RESOURCES=(ingressclass/traefik clusterrole/traefik clusterrolebinding/traefik)
CERT_MANAGER_CLUSTER_ISSUERS=(clusterissuer/letsencrypt-prod clusterissuer/letsencrypt-staging)
# <namespace>/<name> of the scripts/01 secrets that Argo CD cannot recreate.
KEPT_SECRETS=(
  gitea/gitea-admin
  gitea/postgresql-ha-credentials
  gitea/postgresql-ha-pgpool-credentials
  gitea/gitea-metrics-token
  gitea/gitea-app-secrets
  garage/garage-rpc
  anubis/anubis-key
)
PROVIDER_LABEL="app.kubernetes.io/managed-by=auth-providers"
RUNNER_TOKEN_SECRETS=(gitea-runner-registration gitea-api-token)

usage() {
  cat <<'USAGE'
Reset all application workloads in the cluster.

Usage: 05-reset-apps.sh [-f]

Options:
  -f                  Force reset without confirmation
  -h                  Show this help message

Environment variables:
  FORCE_RESET=true    Alternative to -f flag
USAGE
}

force=false
while getopts ":fh" opt; do
  case "${opt}" in
    f) force=true ;;
    h)
      usage
      exit 0
      ;;
    *)
      echo "Invalid option: -${OPTARG}" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${FORCE_RESET:-false}" == "true" ]]; then
  force=true
fi

log "Preparing to reset application workloads..."

if [[ "${force}" != "true" ]]; then
  echo ""
  warn "This will delete ALL application workloads in the cluster"
  read -r -p "Continue? (yes/no) " response
  if [[ ! "${response}" =~ ^[Yy][Ee][Ss]?$ ]]; then
    log "Cancelled"
    exit 0
  fi
fi

require_binary kubectl jq
require_cluster

# Writes the kept secrets as one List manifest, stripped to name, namespace,
# labels, type and data so it can be re-created in fresh namespaces.
save_secrets() {
  local out="$1" ref
  {
    for ref in "${KEPT_SECRETS[@]}"; do
      kubectl get secret "${ref#*/}" -n "${ref%%/*}" -o json 2>/dev/null \
        || warn "Not found, not kept: ${ref}"
    done
    kubectl get secret -n gitea -l "${PROVIDER_LABEL}" -o json | jq '.items[]'
  } | jq -s '{apiVersion: "v1", kind: "List", items: map({
      apiVersion, kind, type, data,
      metadata: {name: .metadata.name, namespace: .metadata.namespace,
                 labels: (.metadata.labels // {})}})}' > "${out}"
}

restore_secrets() {
  local file="$1" ns name
  for ns in gitea gitea-runners anubis garage; do
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
  done
  kubectl apply -f "${file}" >/dev/null || return 1
  for name in "${RUNNER_TOKEN_SECRETS[@]}"; do
    kubectl create secret generic "${name}" -n gitea-runners \
      --from-literal=token=placeholder-update-after-gitea-is-up \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
  done
}

cleanup_namespace() {
  local namespace="$1"

  log "Cleaning up namespace: ${namespace}"

  kubectl delete pods --all -n "${namespace}" --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl delete all,ingress,networkpolicy,configmap,secret,serviceaccount,role,rolebinding,pvc \
    --all -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete ingressroutes,ingressroutetcps,ingressrouteudps,middlewares,middlewaretcps,traefikservices,serverstransports,serverstransporttcps,tlsoptions,tlsstores \
    --all -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete certificates,issuers,certificaterequests \
    --all -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete scaledobjects,triggerauthentications,scaledjobs \
    --all -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true

  log "Deleting namespace: ${namespace}"
  kubectl delete namespace "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true

  local elapsed=0
  while kubectl get namespace "${namespace}" >/dev/null 2>&1 && [[ ${elapsed} -lt 60 ]]; do
    sleep 2
    elapsed=$((elapsed + 2))
  done

  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    local ns_status
    ns_status=$(kubectl get namespace "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    if [[ "${ns_status}" == "Terminating" ]]; then
      warn "Namespace ${namespace} is stuck in Terminating; patching out finalizers"
      kubectl patch namespace "${namespace}" \
        -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      elapsed=0
      while kubectl get namespace "${namespace}" >/dev/null 2>&1 && [[ ${elapsed} -lt 30 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
      done
    fi
  fi

  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    warn "Namespace ${namespace} still exists after cleanup"
  else
    log "Namespace ${namespace} deleted successfully"
  fi
}

cleanup_cluster_scoped_resources() {
  log "Cleaning up cluster-scoped resources"

  local resource
  for resource in "${TRAEFIK_CLUSTER_RESOURCES[@]}"; do
    kubectl delete "${resource}" --ignore-not-found=true >/dev/null 2>&1 || true
  done

  for resource in "${CERT_MANAGER_CLUSTER_ISSUERS[@]}"; do
    kubectl delete "${resource}" --ignore-not-found=true >/dev/null 2>&1 || true
  done
}

step_header 1 "Saving bootstrap and provider secrets"
SAVED_SECRETS="$(mktemp)"
chmod 600 "${SAVED_SECRETS}"
save_secrets "${SAVED_SECRETS}"
log "Saved $(jq '.items | length' "${SAVED_SECRETS}") secret(s) to ${SAVED_SECRETS}"

step_header 2 "Deleting application namespaces"
for namespace in "${APP_NAMESPACES[@]}"; do
  cleanup_namespace "${namespace}"
done

step_header 3 "Removing cluster-scoped resources"
cleanup_cluster_scoped_resources

step_header 4 "Restoring bootstrap and provider secrets"
# On failure the copy stays (mode 600) so nothing is lost; re-run this step by hand.
restore_secrets "${SAVED_SECRETS}" \
  || die "Restore failed; apply ${SAVED_SECRETS} once the namespaces are gone, then delete it"
rm -f "${SAVED_SECRETS}"
log "Restored; runner tokens reset to placeholders"

section_header "Reset Validation"
echo ""
echo "Pods:"
kubectl get pods -A
echo ""
echo "Services:"
kubectl get svc -A
echo ""
echo "Ingresses:"
kubectl get ingress -A
echo ""
log "Reset completed successfully"
