#!/usr/bin/env bash
# Common functions and utilities shared across deployment scripts.
# Source this file at the beginning of any script:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-functions.sh"

set -euo pipefail

# ==============================================================================
# Logging Functions
# ==============================================================================

# Log an informational message with timestamp
log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

# Log a warning message
warn() {
  echo "[$(date '+%H:%M:%S')] [WARN] $*" >&2
}

# Log an error and exit
die() {
  echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2
  exit 1
}

# ==============================================================================
# Validation Functions
# ==============================================================================

# Verify that required binaries exist in PATH
require_binary() {
  local bin
  for bin in "$@"; do
    command -v "${bin}" >/dev/null 2>&1 || die "${bin} not found in PATH"
  done
}

# Verify script is running as root
require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

# Verify Kubernetes cluster is accessible
require_cluster() {
  kubectl cluster-info >/dev/null 2>&1 || die "Cannot reach Kubernetes cluster"
}

# Verify KUBECONFIG is set and points to a valid config
verify_kubeconfig() {
  [[ -n "${KUBECONFIG:-}" ]] || die "KUBECONFIG is not set"
  [[ -f "${KUBECONFIG}" ]] || die "KUBECONFIG file not found: ${KUBECONFIG}"
}

# ==============================================================================
# Kubernetes Utility Functions
# ==============================================================================

# Wait for a resource to exist (with timeout)
wait_for_resource() {
  local resource="$1"
  local timeout="${2:-120}"
  local elapsed=0
  local interval=5

  log "Waiting for ${resource}..."
  while [[ $elapsed -lt $timeout ]]; do
    if kubectl get ${resource} >/dev/null 2>&1; then
      log "${resource} found"
      return 0
    fi
    sleep ${interval}
    elapsed=$((elapsed + interval))
  done

  die "Timeout waiting for ${resource}"
}

# Wait for a resource to be deleted
wait_for_resource_deleted() {
  local resource="$1"
  local timeout="${2:-120}"
  local elapsed=0
  local interval=5

  log "Waiting for ${resource} to be deleted..."
  while [[ $elapsed -lt $timeout ]]; do
    if ! kubectl get ${resource} >/dev/null 2>&1; then
      log "${resource} deleted"
      return 0
    fi
    sleep ${interval}
    elapsed=$((elapsed + interval))
  done

  die "Timeout waiting for ${resource} to be deleted"
}

# Ensure a namespace exists
ensure_namespace() {
  local namespace="$1"

  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    log "Creating namespace: ${namespace}"
    kubectl create namespace "${namespace}"
  else
    log "Namespace exists: ${namespace}"
  fi
}

# Delete a namespace and all its contents
delete_namespace() {
  local namespace="$1"

  log "Deleting namespace: ${namespace}"
  kubectl delete namespace "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
}

# Apply Kustomize overlay
apply_kustomization() {
  local path="$1"
  [[ -d "${path}" ]] || die "Kustomization path not found: ${path}"
  log "Applying: ${path}"
  kubectl apply -k "${path}"
}

# ==============================================================================
# Helm Utility Functions
# ==============================================================================

# Add or update a Helm repository
helm_repo_add() {
  local name="$1"
  local url="$2"

  log "Adding Helm repository: ${name}"
  helm repo add "${name}" "${url}" >/dev/null 2>&1 || true
  helm repo update "${name}" >/dev/null
}

# Check if a Helm release exists
helm_release_exists() {
  local release="$1"
  local namespace="$2"

  if [[ -n "${KUBECONFIG:-}" ]]; then
    helm status "${release}" -n "${namespace}" --kubeconfig "${KUBECONFIG}" >/dev/null 2>&1
  else
    helm status "${release}" -n "${namespace}" >/dev/null 2>&1
  fi
}

# Install or upgrade a Helm release
helm_upgrade_install() {
  local release="$1"
  local chart="$2"
  local namespace="$3"
  shift 3
  local extra_args=("$@")

  log "Installing/upgrading Helm release: ${release} (${chart})"
  if [[ -n "${KUBECONFIG:-}" ]]; then
    helm upgrade --install "${release}" "${chart}" \
      -n "${namespace}" \
      --kubeconfig "${KUBECONFIG}" \
      "${extra_args[@]}"
  else
    helm upgrade --install "${release}" "${chart}" \
      -n "${namespace}" \
      "${extra_args[@]}"
  fi
}

# Uninstall a Helm release
helm_uninstall() {
  local release="$1"
  local namespace="$2"

  if helm_release_exists "${release}" "${namespace}"; then
    log "Uninstalling Helm release: ${release}"
    if [[ -n "${KUBECONFIG:-}" ]]; then
      helm uninstall "${release}" -n "${namespace}" --kubeconfig "${KUBECONFIG}"
    else
      helm uninstall "${release}" -n "${namespace}"
    fi
  fi
}

# ==============================================================================
# Network Utilities
# ==============================================================================

# Wait for a port to become accessible via localhost
wait_for_port() {
  local port="$1"
  local timeout="${2:-120}"
  local elapsed=0
  local interval=2

  log "Waiting for localhost:${port} to be accessible..."
  while [[ $elapsed -lt $timeout ]]; do
    if timeout 2 bash -c ">/dev/tcp/localhost/${port}" 2>/dev/null; then
      log "localhost:${port} is accessible"
      return 0
    fi
    sleep ${interval}
    elapsed=$((elapsed + interval))
  done

  die "Timeout waiting for localhost:${port}"
}

# Wait for HTTP endpoint to return success
wait_for_http() {
  local url="$1"
  local timeout="${2:-120}"
  local elapsed=0
  local interval=3

  log "Waiting for HTTP endpoint: ${url}"
  while [[ $elapsed -lt $timeout ]]; do
    if curl -sf "${url}" >/dev/null 2>&1; then
      log "HTTP endpoint accessible: ${url}"
      return 0
    fi
    sleep ${interval}
    elapsed=$((elapsed + interval))
  done

  die "Timeout waiting for HTTP endpoint: ${url}"
}

# ==============================================================================
# Output Formatting
# ==============================================================================

# Print a section header
section_header() {
  local title="$1"
  echo ""
  echo "================================================================================"
  echo "  ${title}"
  echo "================================================================================"
}

# Print a step header
step_header() {
  local step_num="$1"
  local description="$2"
  log "Step ${step_num}: ${description}"
}

# ==============================================================================
# Node Setup
# ==============================================================================

# Install Longhorn node prerequisites silently
install_node_prerequisites() {
  # log "Installing node prerequisites (open-iscsi, nfs-common)..."
  # DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
  # DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  #   open-iscsi nfs-common >/dev/null 2>&1
  # log "Enabling iscsid service..."
  # systemctl enable --now iscsid >/dev/null 2>&1
  # log "Node prerequisites ready"
  return 0
}

# ==============================================================================
# Cleanup and Safety
# ==============================================================================

# Register a cleanup function to run on exit
on_exit() {
  local handler="$1"
  trap "${handler}" EXIT
}

# Clean up all background jobs on exit
cleanup_jobs() {
  jobs -p | xargs -r kill 2>/dev/null || true
}
