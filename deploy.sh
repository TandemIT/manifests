#!/bin/bash
# Zero-touch full bootstrap: Proxmox VMs (OpenTofu/Terraform) -> K3s +
# platform + Argo CD (Ansible driving scripts/01..03) -> GitOps takes over.
#
# Prerequisites: terraform/terraform.tfvars filled in (see setup.sh), local
# commits PUSHED to the manifests repo (nodes and Argo CD pull from git),
# and the VM template with qemu-guest-agent preinstalled.
#
# Fully non-interactive. Re-running is safe: the infra is declarative and
# the bootstrap scripts are idempotent.
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

if [ ! -f "terraform/terraform.tfvars" ]; then
    echo -e "${RED}Error: terraform/terraform.tfvars not found!${NC}"
    echo "Run ./setup.sh, then edit terraform/terraform.tfvars"
    exit 1
fi

# OpenTofu preferred, Terraform as fallback; override with TF_BIN=... if both
# are installed and you need a specific one (e.g. destroying pre-tofu state).
TF_BIN="${TF_BIN:-$(command -v tofu || command -v terraform || true)}"
if [ -z "${TF_BIN}" ]; then
    echo -e "${RED}Error: neither tofu nor terraform found. Run ./setup.sh first.${NC}"
    exit 1
fi
echo -e "Using IaC binary: ${GREEN}${TF_BIN}${NC}"

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
"${TF_BIN}" -chdir=terraform apply -input=false -auto-approve

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

step "Step 3: Installing system utilities (qemu-guest-agent, micro)"
ansible-playbook -i ansible/inventory.yml ansible/system-utils-install.yml

step "Step 4: Installing K3s cluster + platform + Argo CD"
ansible-playbook -i ansible/inventory.yml ansible/k3s-install.yml

export KUBECONFIG="$(pwd)/kubeconfig"

if ! command -v kubectl &> /dev/null; then
    echo -e "${YELLOW}kubectl not found on this host - skipping the Argo CD convergence wait.${NC}"
    echo "Watch from any master: kubectl get applications -n argocd -w"
    exit 0
fi

step "Step 5: Waiting for Argo CD to converge (up to 20 min)"
deadline=$((SECONDS + 1200))
while :; do
    # Healthy when every Application reports Synced+Healthy (root app included).
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

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<not yet created>")

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
echo "Remaining manual step (after Gitea is up): Atlantis VCS secret +"
echo "Garage layout - scripts/04-deploy-apps.sh steps 10-12 / COMMANDS.md."
