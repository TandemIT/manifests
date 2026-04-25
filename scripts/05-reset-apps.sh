#!/usr/bin/env bash
# Reset application-layer resources.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

APP_NAMESPACES=(cert-manager traefik gitea gitea-runners)
TRAEFIK_CLUSTER_RESOURCES=(ingressclass/traefik clusterrole/traefik clusterrolebinding/traefik)
CERT_MANAGER_CLUSTER_ISSUERS=(clusterissuer/letsencrypt-prod clusterissuer/letsencrypt-staging)
HELM_RELEASES=(
  "gitea:gitea"
)

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

require_binary kubectl helm
require_cluster

cleanup_helm_releases() {
  local namespace="$1"
  local releases

  releases=$(helm list -n "${namespace}" --short 2>/dev/null || true)
  if [[ -z "${releases}" ]]; then
    return 0
  fi

  while IFS= read -r release; do
    [[ -n "${release}" ]] || continue
    log "Uninstalling Helm release: ${release}"
    helm uninstall "${release}" -n "${namespace}" >/dev/null 2>&1 || true
  done <<< "${releases}"
}

cleanup_namespace() {
  local namespace="$1"

  log "Cleaning up namespace: ${namespace}"
  cleanup_helm_releases "${namespace}"

  kubectl delete pods --all -n "${namespace}" --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl delete all,ingress,networkpolicy,configmap,secret,serviceaccount,role,rolebinding,pvc \
    --all -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete ingressroutes,ingressroutetcps,ingressrouteudps,middlewares,middlewaretcps,traefikservices,serverstransports,serverstransporttcps,tlsoptions,tlsstores \
    --all -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete issuers,certificaterequests \
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
    if [[ "${ns_status}" == "Terminating" ]] && kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
      warn "Namespace ${namespace} is stuck in Terminating; restarting metrics-server to refresh discovery"
      kubectl -n kube-system rollout restart deployment metrics-server >/dev/null 2>&1 || true
      sleep 10
      kubectl delete namespace "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
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

step_header 1 "Uninstalling Helm releases"
for release_info in "${HELM_RELEASES[@]}"; do
  release_name="${release_info%%:*}"
  release_namespace="${release_info##*:}"
  if helm status "${release_name}" -n "${release_namespace}" >/dev/null 2>&1; then
    log "Uninstalling: ${release_name} from ${release_namespace}"
    helm uninstall "${release_name}" -n "${release_namespace}" >/dev/null 2>&1 || true
  fi
 done

step_header 2 "Deleting application namespaces"
for namespace in "${APP_NAMESPACES[@]}"; do
  cleanup_namespace "${namespace}"
done

step_header 3 "Removing cluster-scoped resources"
cleanup_cluster_scoped_resources

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
