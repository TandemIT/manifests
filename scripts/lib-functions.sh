#!/usr/bin/env bash
# Shared helpers, sourced by scripts/0*.sh.

set -euo pipefail

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

warn() {
  echo "[$(date '+%H:%M:%S')] [WARN] $*" >&2
}

die() {
  echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2
  exit 1
}

require_binary() {
  local bin
  for bin in "$@"; do
    command -v "${bin}" >/dev/null 2>&1 || die "${bin} not found in PATH"
  done
}

require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

require_cluster() {
  kubectl cluster-info >/dev/null 2>&1 || die "Cannot reach Kubernetes cluster"
}

ensure_namespace() {
  local namespace="$1"

  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    log "Creating namespace: ${namespace}"
    kubectl create namespace "${namespace}"
  else
    log "Namespace exists: ${namespace}"
  fi
}

apply_kustomization() {
  local path="$1"
  shift
  [[ -d "${path}" ]] || die "Kustomization path not found: ${path}"
  log "Applying: ${path}"
  kubectl apply -k "${path}" "$@"
}

section_header() {
  local title="$1"
  echo ""
  echo "================================================================================"
  echo "  ${title}"
  echo "================================================================================"
}

step_header() {
  local step_num="$1"
  local description="$2"
  log "Step ${step_num}: ${description}"
}
