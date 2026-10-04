#!/usr/bin/env bash
# Push Gitea's OIDC/LDAP login providers from terraform.tfvars into the
# cluster. Run from the deploy host (deploy.sh calls it after Ansible);
# re-run after changing gitea_oidc_providers / gitea_ldap_providers.
#
# For each provider it:
#   1. applies the credentials as a plain Secret in the gitea namespace
#      (gitea-oidc-<slug>: key/secret, gitea-ldap-<slug>: bindDn/bindPassword
#      — the key names the Gitea chart's existingSecret expects)
#   2. deletes secrets of providers no longer in terraform.tfvars
#   3. regenerates apps/gitea/values-oidc.yaml / values-ldap.yaml, the
#      non-secret half (names, URLs, filters) that Argo CD reads from git
#
# The credentials never touch git: terraform.tfvars (gitignored) is their
# only source. Every other secret is random and generated in-cluster by
# scripts/01-bootstrap-first-master.sh.
#
# Requirements: kubectl (with cluster access), python3, tofu or terraform
# (override with TF_BIN=).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_BIN="${TF_BIN:-$(command -v tofu || command -v terraform || true)}"
MANAGED_LABEL="app.kubernetes.io/managed-by=auth-providers"

if [[ -z "${KUBECONFIG:-}" && -f "${MANIFESTS_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${MANIFESTS_DIR}/kubeconfig"
fi

require_binary kubectl python3
[[ -n "${TF_BIN}" ]] || die "neither tofu nor terraform found"
require_cluster

tf_output() {
  "${TF_BIN}" -chdir="${MANIFESTS_DIR}/terraform" output -json "$1" 2>/dev/null || echo "{}"
}

step_header 1 "Reading providers from terraform.tfvars"
export OIDC_JSON LDAP_JSON
OIDC_JSON="$(tf_output gitea_oidc_providers)"
LDAP_JSON="$(tf_output gitea_ldap_providers)"
log "OIDC: $(python3 -c "import json,os; print(len(json.loads(os.environ['OIDC_JSON'])))") provider(s), LDAP: $(python3 -c "import json,os; print(len(json.loads(os.environ['LDAP_JSON'])))") provider(s)"

step_header 2 "Applying provider secrets"
SECRETS_JSON="$(python3 -c "
import json, os
oidc = json.loads(os.environ['OIDC_JSON'])
ldap = json.loads(os.environ['LDAP_JSON'])
def secret(name, data):
    return {'apiVersion': 'v1', 'kind': 'Secret',
            'metadata': {'name': name, 'namespace': 'gitea',
                         'labels': {'app.kubernetes.io/managed-by': 'auth-providers'}},
            'stringData': data}
items = [secret(f'gitea-oidc-{s}', {'key': p['client_id'], 'secret': p['client_secret']})
         for s, p in oidc.items()]
items += [secret(f'gitea-ldap-{s}', {'bindDn': p['bind_dn'], 'bindPassword': p['bind_password']})
          for s, p in ldap.items()]
print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}) if items else '')
")"
if [[ -n "${SECRETS_JSON}" ]]; then
  echo "${SECRETS_JSON}" | kubectl apply -f -
else
  log "No providers configured"
fi

WANTED="$(python3 -c "
import json, os
print(' '.join([f'gitea-oidc-{s}' for s in json.loads(os.environ['OIDC_JSON'])]
             + [f'gitea-ldap-{s}' for s in json.loads(os.environ['LDAP_JSON'])]))
")"
for NAME in ${WANTED}; do
  # Secrets created by the former sealed-secrets controller are owned by a
  # SealedSecret CR; drop that link so removing the CR does not
  # garbage-collect the secret.
  if [[ -n "$(kubectl get secret "${NAME}" -n gitea -o jsonpath='{.metadata.ownerReferences}')" ]]; then
    kubectl patch secret "${NAME}" -n gitea --type=json \
      -p '[{"op":"remove","path":"/metadata/ownerReferences"}]' >/dev/null
    log "Detached: gitea/${NAME} from its SealedSecret owner"
  fi
done

step_header 3 "Removing secrets of deleted providers"
for NAME in $(kubectl get secret -n gitea -l "${MANAGED_LABEL}" -o jsonpath='{.items[*].metadata.name}'); do
  [[ " ${WANTED} " == *" ${NAME} "* ]] && continue
  kubectl delete secret "${NAME}" -n gitea >/dev/null
  log "Deleted: gitea/${NAME}"
done

step_header 4 "Generating Gitea values files"
python3 -c "
import json, os
d = json.loads(os.environ['OIDC_JSON'])
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

python3 -c "
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

# Argo CD reads the values files from git, not from this checkout.
if ! git -C "${MANIFESTS_DIR}" diff --quiet -- apps/gitea/values-oidc.yaml apps/gitea/values-ldap.yaml; then
  warn "apps/gitea/values-oidc.yaml / values-ldap.yaml changed — commit and push"
  warn "them, or Gitea keeps the provider list that is currently in git."
else
  log "Values files match git"
fi
