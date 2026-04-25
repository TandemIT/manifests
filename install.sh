#!/bin/bash
# Entry point: bootstraps the FIRST control plane node.
# Clone this repo to all nodes, then run:
#   master1 : sudo bash install.sh
#   master2/3: sudo K3S_TOKEN='<token>' bash scripts/02-join-control-plane.sh
#   worker1-3: sudo K3S_TOKEN='<token>' bash scripts/03-join-worker.sh
#
# See COMMANDS.md for the full step-by-step guide.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer bash over exec, because of permission issues.
bash "${SCRIPT_DIR}/scripts/01-bootstrap-first-master.sh" "$@"
