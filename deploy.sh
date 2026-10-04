#!/bin/bash
# Full bootstrap: VMs (tofu) -> K3s + platform + Argo CD (Ansible running
# scripts/01..03) -> GitOps. Steps and prerequisites: README.md. Safe to re-run.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step() { echo -e "\n${GREEN}==> $1${NC}"; }

cd "$(dirname "$0")"

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}K3s on Proxmox - Full Bootstrap${NC}"
echo -e "${GREEN}================================${NC}"

# Settings are committed (terraform/cluster.auto.tfvars). Credentials come
# from terraform/terraform.tfvars (local, gitignored) or TF_VAR_* (CI).
if [ ! -f "terraform/terraform.tfvars" ] && [ -z "${TF_VAR_proxmox_api_token_secret:-}" ]; then
    echo -e "${RED}Error: no credentials: terraform/terraform.tfvars not found and TF_VAR_proxmox_api_token_secret not set${NC}"
    echo "Run ./setup.sh, then fill in terraform/terraform.tfvars"
    exit 1
fi

# Kept out of terraform.tfvars on purpose.
if [ -z "${TF_VAR_vm_password:-}" ]; then
    echo -e "${RED}Error: TF_VAR_vm_password is not set!${NC}"
    echo "export TF_VAR_vm_password='<at least 12 chars>' (cloud-init user's password on every VM)"
    exit 1
fi

if [ -z "${TF_VAR_state_passphrase:-}" ]; then
    echo -e "${RED}Error: TF_VAR_state_passphrase is not set!${NC}"
    echo "export TF_VAR_state_passphrase='<at least 16 chars>' (decrypts the OpenTofu state)"
    exit 1
fi

# State lives in Gitea's package registry (terraform/main.tf backend "http").
# Without Gitea (first bootstrap, rebuild) terraform/backend_override.tf
# switches to a local file instead: COMMANDS.md, State.
if [ -f terraform/backend_override.tf ]; then
    echo -e "${YELLOW}terraform/backend_override.tf present: state is NOT in Gitea this run.${NC}"
else
    for v in TF_HTTP_ADDRESS TF_HTTP_USERNAME TF_HTTP_PASSWORD; do
        if [ -z "${!v:-}" ]; then
            echo -e "${RED}Error: ${v} is not set!${NC}"
            echo "TF_HTTP_ADDRESS=https://git.open-ict.hu/api/packages/Cloud-Infra/terraform/state/k3s-proxmox"
            echo "TF_HTTP_USERNAME / TF_HTTP_PASSWORD: a Gitea user and token with write:package"
            echo "No Gitea yet (first bootstrap or rebuild)? See COMMANDS.md, State."
            exit 1
        fi
    done
    export TF_HTTP_LOCK_ADDRESS="${TF_HTTP_ADDRESS}/lock"
    export TF_HTTP_UNLOCK_ADDRESS="${TF_HTTP_ADDRESS}/lock"
fi

# OpenTofu only: terraform/main.tf uses state encryption, which Terraform
# doesn't support. TF_BIN=... picks a specific tofu binary.
TF_BIN="${TF_BIN:-$(command -v tofu || true)}"
if [ -z "${TF_BIN}" ]; then
    echo -e "${RED}Error: tofu not found. Run ./setup.sh first.${NC}"
    exit 1
fi
echo -e "Using IaC binary: ${GREEN}${TF_BIN}${NC}"

# Checked up front so a missing kubectl doesn't stop the run halfway.
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found. Run ./setup.sh first.${NC}"
    exit 1
fi

if ! command -v ansible-playbook &> /dev/null; then
    echo -e "${YELLOW}Ansible not found. Installing...${NC}"
    sudo apt update
    sudo apt install -y ansible
fi

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo -e "${YELLOW}Warning: uncommitted changes in this repo. Nodes and Argo CD${NC}"
    echo -e "${YELLOW}pull from the git remote - unpushed changes will NOT be deployed.${NC}"
fi

step "Step 1: Provisioning VMs (also generates ansible/inventory.yml)"
"${TF_BIN}" -chdir=terraform init -input=false
# Saved plan, checked before applying: deleting or replacing a VM takes
# nodes down (all affected count instances at once, CLAUDE.md), so it is
# refused unless ALLOW_VM_DESTROY=true. The plan file holds secrets in
# plaintext; it lives in a private temp dir and is removed on exit.
PLAN_DIR="$(mktemp -d)"
trap 'rm -rf "${PLAN_DIR}"' EXIT
"${TF_BIN}" -chdir=terraform plan -input=false -out="${PLAN_DIR}/tfplan"
vm_destroys=$("${TF_BIN}" -chdir=terraform show -json "${PLAN_DIR}/tfplan" | jq -r '
    .resource_changes[]?
    | select(.type == "proxmox_vm_qemu" and (.change.actions | index("delete")))
    | "\(.address) (\(.change.actions | join("+")))"')
if [ -n "${vm_destroys}" ] && [ "${ALLOW_VM_DESTROY:-}" != "true" ]; then
    echo -e "${RED}Refusing: this plan deletes or replaces VMs:${NC}"
    echo "${vm_destroys}"
    echo "Rebuild nodes one at a time (CLAUDE.md, terraform/), or set ALLOW_VM_DESTROY=true."
    exit 1
fi
"${TF_BIN}" -chdir=terraform apply -input=false "${PLAN_DIR}/tfplan"

CONTROL_PLANE_IP=$("${TF_BIN}" -chdir=terraform output -json control_plane_ips | jq -r '.[0]')
mapfile -t ALL_NODE_IPS < <("${TF_BIN}" -chdir=terraform output -json control_plane_ips | jq -r '.[]'; \
                            "${TF_BIN}" -chdir=terraform output -json worker_ips | jq -r '.[]')

step "Step 2: Waiting for SSH on all ${#ALL_NODE_IPS[@]} nodes"
# UserKnownHostsFile=/dev/null: rebuilt VMs reuse IPs with fresh host keys.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
for NODE_IP in "${ALL_NODE_IPS[@]}"; do
    retries=0
    until ssh "${SSH_OPTS[@]}" "ubuntu@${NODE_IP}" "echo ok" &> /dev/null; do
        retries=$((retries+1))
        if [ $retries -ge 30 ]; then
            echo -e "${RED}No SSH on ${NODE_IP} after 30 attempts${NC}"
            exit 1
        fi
        echo "Waiting for SSH on ${NODE_IP}... (attempt $retries/30)"
        sleep 10
    done
    echo "SSH OK: ${NODE_IP}"
done

step "Step 3: Installing system utilities (qemu-guest-agent, micro, unattended-upgrades, public0 NIC)"
ansible-playbook -i ansible/inventory.yml ansible/system-utils-install.yml

step "Step 4: Installing K3s cluster + platform + Argo CD"
ansible-playbook -i ansible/inventory.yml ansible/k3s-install.yml

KUBECONFIG="$(pwd)/kubeconfig"
export KUBECONFIG

# Gitea (wave 6) needs these Secrets; push them while earlier waves sync.
step "Step 5: Pushing Gitea login providers from terraform.tfvars"
TF_BIN="${TF_BIN}" bash scripts/06-auth-providers.sh

step "Step 6: Waiting for Argo CD to converge (up to 20 min)"
deadline=$((SECONDS + 1200))
while :; do
    total=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l)
    ready=$(kubectl get applications -n argocd --no-headers 2>/dev/null | awk '$2=="Synced" && $3=="Healthy"' | wc -l)
    if [ "${total}" -gt 1 ] && [ "${ready}" -eq "${total}" ]; then
        echo -e "${GREEN}All ${total} Argo CD applications are Synced + Healthy${NC}"
        break
    fi
    if [ $SECONDS -ge $deadline ]; then
        echo -e "${YELLOW}Timed out waiting; current state (bootstrap continues in-cluster):${NC}"
        break
    fi
    echo "Argo CD: ${ready}/${total} applications Synced+Healthy..."
    sleep 20
done
kubectl get applications -n argocd 2>/dev/null || true

# Never print it in CI (.gitea/workflows/deploy.yml): job logs are readable.
if [ "${CI:-}" = "true" ]; then
    ARGOCD_PASS="<hidden in CI: kubectl -n argocd get secret argocd-initial-admin-secret>"
else
    ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<not yet created>")
fi

echo -e "\n${GREEN}================================${NC}"
echo -e "${GREEN}Deployment Complete${NC}"
echo -e "${GREEN}================================${NC}"
"${TF_BIN}" -chdir=terraform output cluster_info
echo ""
echo "Cluster access:"
echo -e "  ${YELLOW}export KUBECONFIG=$(pwd)/kubeconfig${NC}"
echo -e "  ${YELLOW}kubectl get nodes${NC}"
echo ""
echo "Argo CD:"
echo -e "  ${YELLOW}kubectl port-forward svc/argocd-server -n argocd 8080:443${NC}"
echo "  Login: admin / ${ARGOCD_PASS}"
echo ""
echo "SSH to first control plane:"
echo -e "  ${YELLOW}ssh ubuntu@${CONTROL_PLANE_IP}${NC}"
echo ""
echo "No further manual steps: runner tokens and Garage credentials mint"
echo "automatically via in-cluster bootstrap Jobs once Gitea is up."
