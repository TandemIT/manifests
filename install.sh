#!/bin/bash
# Bootstraps the first control plane (manual setup, see README.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# bash, not exec: works without the executable bit.
bash "${SCRIPT_DIR}/scripts/01-bootstrap-first-master.sh" "$@"
