#!/usr/bin/env bash
# Seal cluster secrets into git-committable SealedSecret manifests.
#
# Turns the imperatively-created secrets (scripts/01/04) into SealedSecret
# files that Argo CD syncs like any other manifest. For each secret it:
#   1. reuses the live in-cluster value when one exists (migration never
#      rotates credentials), otherwise generates or prompts for a value
#   2. writes the SealedSecret next to the app that consumes it
#   3. adds the file to that app's kustomization.yaml
#   4. annotates the live secret so the controller is allowed to adopt it
#
# Sealed files (commit all of them):
#   apps/gitea/sealedsecret-gitea-admin.yaml
#   apps/gitea/sealedsecret-gitea-oidc-<slug>.yaml (optional, one per OIDC provider)
#   apps/gitea/sealedsecret-gitea-ldap-<slug>.yaml (optional, one per LDAP provider)
#   apps/anubis/sealedsecret-anubis-key.yaml
#   apps/atlantis/garage/sealedsecret-garage-rpc.yaml
#   apps/atlantis/sealedsecret-atlantis-vcs.yaml   (optional, prompted)
#
# Runtime tokens (runner registration, KEDA API, Garage S3) are NOT sealed —
# they are minted in-cluster by the bootstrap Jobs in apps/gitea-runner/ and
# apps/atlantis/garage/.
#
# Requirements: kubectl (with cluster access), kubeseal, openssl.
# The sealed-secrets controller (argocd/apps/sealed-secrets.yaml) must be
# running — kubeseal fetches its public certificate on first use.
#
# Idempotent: existing sealedsecret-*.yaml files are left untouched. To
# rotate a secret, delete its file and re-run this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT="${MANIFESTS_DIR}/sealed-secrets-cert.pem"
CONTROLLER_NAME="sealed-secrets-controller"
CONTROLLER_NS="kube-system"

if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  elif [[ -f "${HOME}/.kube/config" ]]; then
    export KUBECONFIG="${HOME}/.kube/config"
  fi
fi

require_binary kubectl kubeseal openssl python3
require_cluster

# Read a key from a live in-cluster secret; empty output when absent.
live_value() {
  local name="$1" ns="$2" key="$3"
  kubectl get secret "${name}" -n "${ns}" -o jsonpath="{.data.${key}}" 2>/dev/null \
    | base64 -d 2>/dev/null || true
}

# Allow the controller to take ownership of a pre-existing plain secret.
# Without this annotation it refuses to overwrite secrets it did not create.
mark_managed() {
  local name="$1" ns="$2"
  if kubectl get secret "${name}" -n "${ns}" >/dev/null 2>&1; then
    kubectl annotate secret "${name}" -n "${ns}" \
      sealedsecrets.bitnami.com/managed=true --overwrite >/dev/null
  fi
}

# seal_secret <name> <namespace> <outfile> key=value...
seal_secret() {
  local name="$1" ns="$2" outfile="$3"
  shift 3
  local args=()
  local kv
  for kv in "$@"; do
    args+=(--from-literal="${kv}")
  done
  kubectl create secret generic "${name}" -n "${ns}" "${args[@]}" \
    --dry-run=client -o yaml \
    | kubeseal --cert "${CERT}" --format yaml > "${outfile}"
  mark_managed "${name}" "${ns}"
  log "Sealed: ${ns}/${name} -> ${outfile#"${MANIFESTS_DIR}"/}"
}

# Add a resource entry to a kustomization.yaml if it is not already listed.
add_resource() {
  local kfile="$1" entry="$2"
  if ! grep -qE "^[[:space:]]*-[[:space:]]*${entry}[[:space:]]*$" "${kfile}"; then
    sed -i "s|^resources:|resources:\n  - ${entry}|" "${kfile}"
    log "Wired: ${entry} into ${kfile#"${MANIFESTS_DIR}"/}"
  fi
}

# The cert is a public key — safe to commit, so future sealing works offline
# from any checkout.
step_header 1 "Fetching sealed-secrets public certificate"
if [[ ! -f "${CERT}" ]]; then
  kubeseal --fetch-cert \
    --controller-name "${CONTROLLER_NAME}" \
    --controller-namespace "${CONTROLLER_NS}" > "${CERT}" \
    || die "Cannot fetch certificate — is the sealed-secrets Application synced yet?"
  log "Saved: ${CERT#"${MANIFESTS_DIR}"/} (public key, commit it)"
else
  log "Using cached certificate: ${CERT#"${MANIFESTS_DIR}"/}"
fi

step_header 2 "Sealing gitea/gitea-admin"
OUT="${MANIFESTS_DIR}/apps/gitea/sealedsecret-gitea-admin.yaml"
if [[ -f "${OUT}" ]]; then
  log "Exists: ${OUT#"${MANIFESTS_DIR}"/} (delete the file to rotate)"
else
  ADMIN_USER="$(live_value gitea-admin gitea username)"
  ADMIN_PASS="$(live_value gitea-admin gitea password)"
  ADMIN_EMAIL="$(live_value gitea-admin gitea email)"
  ADMIN_NEW=false
  if [[ -z "${ADMIN_PASS}" ]]; then
    ADMIN_USER="${ADMIN_USER:-gitea-admin}"
    ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
    ADMIN_PASS="$(openssl rand -hex 24)"
    ADMIN_NEW=true
  else
    log "Reusing live credentials — the admin password does not change"
  fi
  seal_secret gitea-admin gitea "${OUT}" \
    "username=${ADMIN_USER}" "password=${ADMIN_PASS}" "email=${ADMIN_EMAIL}"
  add_resource "${MANIFESTS_DIR}/apps/gitea/kustomization.yaml" sealedsecret-gitea-admin.yaml
  if [[ "${ADMIN_NEW}" == "true" ]]; then
    echo ""
    echo "  Initial Gitea login (record it now — it is not stored in plaintext anywhere):"
    echo "    username: ${ADMIN_USER}"
    echo "    password: ${ADMIN_PASS}"
    echo "  Retrievable later from the live cluster:"
    echo "    kubectl get secret gitea-admin -n gitea -o jsonpath='{.data.password}' | base64 -d"
    echo ""
  fi
fi

step_header 3 "Sealing atlantis/garage-rpc"
OUT="${MANIFESTS_DIR}/apps/atlantis/garage/sealedsecret-garage-rpc.yaml"
if [[ -f "${OUT}" ]]; then
  log "Exists: ${OUT#"${MANIFESTS_DIR}"/}"
else
  RPC="$(live_value garage-rpc atlantis rpc-secret)"
  [[ -n "${RPC}" ]] || RPC="$(openssl rand -hex 32)"
  seal_secret garage-rpc atlantis "${OUT}" "rpc-secret=${RPC}"
  add_resource "${MANIFESTS_DIR}/apps/atlantis/garage/kustomization.yaml" sealedsecret-garage-rpc.yaml
fi

step_header 4 "Sealing anubis/anubis-key"
OUT="${MANIFESTS_DIR}/apps/anubis/sealedsecret-anubis-key.yaml"
if [[ -f "${OUT}" ]]; then
  log "Exists: ${OUT#"${MANIFESTS_DIR}"/}"
else
  ANUBIS="$(live_value anubis-key anubis ED25519_PRIVATE_KEY_HEX)"
  [[ -n "${ANUBIS}" ]] || ANUBIS="$(openssl rand -hex 32)"
  seal_secret anubis-key anubis "${OUT}" "ED25519_PRIVATE_KEY_HEX=${ANUBIS}"
  add_resource "${MANIFESTS_DIR}/apps/anubis/kustomization.yaml" sealedsecret-anubis-key.yaml
fi

# Optional — needs an OAuth2 provider/application per entry, created by you.
# Supports any number of providers: terraform.tfvars' gitea_oidc_providers is
# a map, keyed by slug. Falls back to a single interactive provider when
# terraform.tfvars has none configured.
step_header 5 "Sealing gitea OIDC providers"

PROVIDERS_JSON="{}"
if command -v terraform >/dev/null 2>&1 && [[ -f "${MANIFESTS_DIR}/terraform/terraform.tfvars" ]]; then
  PROVIDERS_JSON="$(terraform -chdir="${MANIFESTS_DIR}/terraform" output -json gitea_oidc_providers 2>/dev/null || echo "{}")"
fi

if [[ "${PROVIDERS_JSON}" == "{}" ]]; then
  echo ""
  read -rp "  Configure Gitea OIDC login (no providers found in terraform.tfvars)? [y/N]: " OIDC_ANSWER
  if [[ "${OIDC_ANSWER,,}" == "y" ]]; then
    read -rp "  Display name (e.g. Authentik): " OIDC_NAME
    read -rp "  OIDC Client ID:     " OIDC_KEY
    read -rsp "  OIDC Client Secret: " OIDC_SECRET
    echo ""
    read -rp "  Discovery URL:      " OIDC_DISCOVERY
    read -rp "  Icon URL (optional): " OIDC_ICON
    SLUG="$(echo "${OIDC_NAME}" | tr '[:upper:] ' '[:lower:]-')"
    PROVIDERS_JSON="$(SLUG="${SLUG}" OIDC_NAME="${OIDC_NAME}" OIDC_KEY="${OIDC_KEY}" \
      OIDC_SECRET="${OIDC_SECRET}" OIDC_DISCOVERY="${OIDC_DISCOVERY}" OIDC_ICON="${OIDC_ICON}" \
      python3 -c "
import os, json
print(json.dumps({os.environ['SLUG']: {
    'display_name': os.environ['OIDC_NAME'],
    'client_id': os.environ['OIDC_KEY'],
    'client_secret': os.environ['OIDC_SECRET'],
    'discovery_url': os.environ['OIDC_DISCOVERY'],
    'icon_url': os.environ.get('OIDC_ICON', ''),
}}))
")"
  else
    log "Skipping OIDC — add entries to gitea_oidc_providers in terraform.tfvars, or answer y next run"
  fi
fi

while IFS=$'\t' read -r SLUG CID CSECRET; do
  [[ -n "${SLUG}" ]] || continue
  OUT="${MANIFESTS_DIR}/apps/gitea/sealedsecret-gitea-oidc-${SLUG}.yaml"
  SECRET_NAME="gitea-oidc-${SLUG}"
  if [[ -f "${OUT}" ]]; then
    log "Exists: ${OUT#"${MANIFESTS_DIR}"/}"
    continue
  fi
  LIVE_KEY="$(live_value "${SECRET_NAME}" gitea key)"
  LIVE_SECRET="$(live_value "${SECRET_NAME}" gitea secret)"
  if [[ -n "${LIVE_KEY}" && -n "${LIVE_SECRET}" ]]; then
    log "Reusing live OIDC client credentials for ${SLUG}"
    CID="${LIVE_KEY}"
    CSECRET="${LIVE_SECRET}"
  fi
  seal_secret "${SECRET_NAME}" gitea "${OUT}" "key=${CID}" "secret=${CSECRET}"
  add_resource "${MANIFESTS_DIR}/apps/gitea/kustomization.yaml" "sealedsecret-gitea-oidc-${SLUG}.yaml"
done < <(PROVIDERS_JSON="${PROVIDERS_JSON}" python3 -c "
import json, os
d = json.loads(os.environ['PROVIDERS_JSON'])
for slug, p in d.items():
    print('\t'.join([slug, p.get('client_id', ''), p.get('client_secret', '')]))
")

# Regenerate the Gitea Helm values for OIDC from scratch every run, so
# removing a provider from terraform.tfvars also removes its login button
# (the sealed secret file itself is left in place — delete it by hand to
# fully rotate/remove a provider).
PROVIDERS_JSON="${PROVIDERS_JSON}" python3 -c "
import json, os
d = json.loads(os.environ['PROVIDERS_JSON'])
lines = ['gitea:']
if not d:
    lines.append('  oauth: []')
else:
    lines.append('  oauth:')
    for slug, p in d.items():
        lines.append(f'    - name: {json.dumps(p.get(\"display_name\", slug))}')
        lines.append('      provider: openidConnect')
        lines.append(f'      existingSecret: {json.dumps(f\"gitea-oidc-{slug}\")}')
        lines.append(f'      autoDiscoverUrl: {json.dumps(p.get(\"discovery_url\", \"\"))}')
        icon = p.get('icon_url', '')
        if icon:
            lines.append(f'      iconUrl: {json.dumps(icon)}')
        lines.append('      scopes: \"email profile gitea\"')
        lines.append('      groupClaimName: gitea')
        lines.append('      adminGroup: admin')
        lines.append('      restrictedGroup: restricted')
print('\n'.join(lines))
" > "${MANIFESTS_DIR}/apps/gitea/values-oidc.yaml"
PROVIDER_COUNT="$(PROVIDERS_JSON="${PROVIDERS_JSON}" python3 -c "import json,os; print(len(json.loads(os.environ['PROVIDERS_JSON'])))")"
log "Generated: apps/gitea/values-oidc.yaml (${PROVIDER_COUNT} provider(s))"

# Optional — needs an LDAP/AD server (or an Authentik LDAP outpost) per
# entry. Same shape as the OIDC block above: terraform.tfvars'
# gitea_ldap_providers is a map keyed by slug, sealed into one secret per
# provider (bindDn/bindPassword — the key names the Gitea chart expects),
# then apps/gitea/values-ldap.yaml is regenerated from scratch every run.
step_header 6 "Sealing gitea LDAP providers"

LDAP_JSON="{}"
if command -v terraform >/dev/null 2>&1 && [[ -f "${MANIFESTS_DIR}/terraform/terraform.tfvars" ]]; then
  LDAP_JSON="$(terraform -chdir="${MANIFESTS_DIR}/terraform" output -json gitea_ldap_providers 2>/dev/null || echo "{}")"
fi
if [[ "${LDAP_JSON}" == "{}" ]]; then
  log "No LDAP providers in terraform.tfvars — skipping (gitea_ldap_providers)"
fi

while IFS=$'\t' read -r SLUG BIND_DN BIND_PASSWORD; do
  [[ -n "${SLUG}" ]] || continue
  OUT="${MANIFESTS_DIR}/apps/gitea/sealedsecret-gitea-ldap-${SLUG}.yaml"
  SECRET_NAME="gitea-ldap-${SLUG}"
  if [[ -f "${OUT}" ]]; then
    log "Exists: ${OUT#"${MANIFESTS_DIR}"/}"
    continue
  fi
  LIVE_DN="$(live_value "${SECRET_NAME}" gitea bindDn)"
  LIVE_PASSWORD="$(live_value "${SECRET_NAME}" gitea bindPassword)"
  if [[ -n "${LIVE_DN}" && -n "${LIVE_PASSWORD}" ]]; then
    log "Reusing live LDAP bind credentials for ${SLUG}"
    BIND_DN="${LIVE_DN}"
    BIND_PASSWORD="${LIVE_PASSWORD}"
  fi
  seal_secret "${SECRET_NAME}" gitea "${OUT}" "bindDn=${BIND_DN}" "bindPassword=${BIND_PASSWORD}"
  add_resource "${MANIFESTS_DIR}/apps/gitea/kustomization.yaml" "sealedsecret-gitea-ldap-${SLUG}.yaml"
done < <(LDAP_JSON="${LDAP_JSON}" python3 -c "
import json, os
d = json.loads(os.environ['LDAP_JSON'])
for slug, p in d.items():
    print('\t'.join([slug, p.get('bind_dn', ''), p.get('bind_password', '')]))
")

LDAP_JSON="${LDAP_JSON}" python3 -c "
import json, os
d = json.loads(os.environ['LDAP_JSON'])
lines = ['gitea:']
if not d:
    lines.append('  ldap: []')
else:
    lines.append('  ldap:')
    for slug, p in d.items():
        lines.append(f'    - name: {json.dumps(p.get(\"display_name\", slug))}')
        lines.append(f'      existingSecret: {json.dumps(f\"gitea-ldap-{slug}\")}')
        lines.append(f'      securityProtocol: {json.dumps(p.get(\"security_protocol\", \"LDAPS\"))}')
        lines.append(f'      host: {json.dumps(p.get(\"host\", \"\"))}')
        lines.append(f'      port: {json.dumps(str(p.get(\"port\", \"\")))}')
        lines.append(f'      userSearchBase: {json.dumps(p.get(\"user_search_base\", \"\"))}')
        lines.append(f'      userFilter: {json.dumps(p.get(\"user_filter\", \"\"))}')
        admin_filter = p.get('admin_filter', '')
        if admin_filter:
            lines.append(f'      adminFilter: {json.dumps(admin_filter)}')
        lines.append(f'      emailAttribute: {json.dumps(p.get(\"email_attribute\", \"mail\"))}')
        lines.append(f'      usernameAttribute: {json.dumps(p.get(\"username_attribute\", \"uid\"))}')
        ssh_attr = p.get('public_ssh_key_attribute', '')
        if ssh_attr:
            lines.append(f'      publicSSHKeyAttribute: {json.dumps(ssh_attr)}')
print('\n'.join(lines))
" > "${MANIFESTS_DIR}/apps/gitea/values-ldap.yaml"
LDAP_COUNT="$(LDAP_JSON="${LDAP_JSON}" python3 -c "import json,os; print(len(json.loads(os.environ['LDAP_JSON'])))")"
log "Generated: apps/gitea/values-ldap.yaml (${LDAP_COUNT} provider(s))"

# Optional — needs a Gitea bot account + API token.
step_header 7 "Sealing atlantis/atlantis-vcs"
OUT="${MANIFESTS_DIR}/apps/atlantis/sealedsecret-atlantis-vcs.yaml"
if [[ -f "${OUT}" ]]; then
  log "Exists: ${OUT#"${MANIFESTS_DIR}"/}"
else
  VCS_USER="$(live_value atlantis-vcs atlantis username)"
  VCS_TOKEN="$(live_value atlantis-vcs atlantis token)"
  VCS_WEBHOOK="$(live_value atlantis-vcs atlantis webhook-secret)"
  VCS_TF="$(live_value atlantis-vcs atlantis tf-token)"
  if [[ -n "${VCS_TOKEN}" ]]; then
    log "Reusing live Atlantis VCS credentials"
  else
    echo ""
    read -rp "  Configure Atlantis VCS credentials (Gitea bot account)? [y/N]: " VCS_ANSWER
    if [[ "${VCS_ANSWER,,}" == "y" ]]; then
      read -rp "  Gitea bot username:    " VCS_USER
      read -rsp "  Gitea API token:       " VCS_TOKEN
      echo ""
      read -rp "  Terraform secret:      " VCS_TF
      read -rsp "  Webhook secret:        " VCS_WEBHOOK
      echo ""
    else
      VCS_TOKEN=""
      log "Skipping Atlantis VCS — re-run this script once the bot account exists"
    fi
  fi
  if [[ -n "${VCS_TOKEN}" ]]; then
    seal_secret atlantis-vcs atlantis "${OUT}" \
      "username=${VCS_USER}" "token=${VCS_TOKEN}" \
      "webhook-secret=${VCS_WEBHOOK}" "tf-token=${VCS_TF}"
    add_resource "${MANIFESTS_DIR}/apps/atlantis/kustomization.yaml" sealedsecret-atlantis-vcs.yaml
  fi
fi

section_header "Sealing complete"
echo ""
echo "Next steps:"
echo "  1. git add -A && git commit && git push — Argo CD takes ownership on sync."
echo ""
echo "IMPORTANT — back up the sealing keypair off-cluster (without it, a cluster"
echo "rebuild makes every SealedSecret in git undecryptable):"
echo "  kubectl get secret -n kube-system \\"
echo "    -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealing-key-backup.yaml"
echo "Restore on a fresh cluster with: kubectl apply -f sealing-key-backup.yaml"
echo "(then restart the sealed-secrets-controller deployment)."
echo "================================================================================"
