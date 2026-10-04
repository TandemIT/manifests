#!/usr/bin/env bash
# Off-cluster copy of the OpenTofu state, which otherwise lives only in Gitea
# inside the cluster it manages. Downloads the state as stored (encrypted, see
# terraform/main.tf) into state-backups/, so the copy needs no passphrase and
# reveals nothing without it. Run after every apply (CI or deploy.sh).
# Needs curl and TF_HTTP_ADDRESS / TF_HTTP_USERNAME / TF_HTTP_PASSWORD (as for
# deploy.sh); a read:package token is enough.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-functions.sh
source "${SCRIPT_DIR}/lib-functions.sh"

require_binary curl
for v in TF_HTTP_ADDRESS TF_HTTP_USERNAME TF_HTTP_PASSWORD; do
  [[ -n "${!v:-}" ]] || die "${v} is not set (see deploy.sh)"
done

OUT_DIR="${SCRIPT_DIR}/../state-backups"
mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"
out="${OUT_DIR}/$(basename "${TF_HTTP_ADDRESS}")-$(date -u '+%Y%m%dT%H%M%SZ').tfstate"

curl -sSf -u "${TF_HTTP_USERNAME}:${TF_HTTP_PASSWORD}" -o "${out}.part" "${TF_HTTP_ADDRESS}" \
  || die "Download failed: ${TF_HTTP_ADDRESS}"

# Refuse to keep a plaintext copy: everything written since the migration
# must be encrypted (terraform/main.tf, enforced = true).
grep -q '"encrypted_data"' "${out}.part" \
  || { rm -f "${out}.part"; die "State is not encrypted - not saved. Check terraform/main.tf encryption."; }

mv "${out}.part" "${out}"
chmod 600 "${out}"
log "Saved ${out}"
log "Keep state-backups/ off this machine too, with the passphrase stored separately."
