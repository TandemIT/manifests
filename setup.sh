#!/bin/bash
# One-time prerequisite check/setup for the full bootstrap (see deploy.sh).
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cd "$(dirname "$0")"

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}K3s Proxmox Setup - Prerequisites${NC}"
echo -e "${GREEN}================================${NC}"

if [ ! -f "terraform/terraform.tfvars" ]; then
    cp terraform/terraform.tfvars.example terraform/terraform.tfvars
    echo -e "${YELLOW}Created terraform/terraform.tfvars - edit it with your Proxmox API token and network settings!${NC}"
else
    echo -e "${GREEN}terraform/terraform.tfvars exists${NC}"
fi

chmod +x deploy.sh setup.sh 2>/dev/null || true

echo -e "\n${GREEN}Checking prerequisites...${NC}"

# OpenTofu preferred; an existing Terraform install works too (deploy.sh
# auto-detects, tofu first). Installs OpenTofu if neither is present.
if command -v tofu &> /dev/null; then
    echo -e "${GREEN}[ok] OpenTofu: $(tofu version | head -n1)${NC}"
elif command -v terraform &> /dev/null; then
    echo -e "${GREEN}[ok] Terraform: $(terraform version | head -n1) (OpenTofu also works - deploy.sh prefers tofu if installed)${NC}"
else
    echo -e "${YELLOW}[--] Neither tofu nor terraform found. Installing OpenTofu...${NC}"
    curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh
    chmod +x /tmp/install-opentofu.sh
    /tmp/install-opentofu.sh --install-method deb
    rm -f /tmp/install-opentofu.sh
    echo -e "${GREEN}[ok] OpenTofu: $(tofu version | head -n1)${NC}"
fi

if command -v ansible &> /dev/null; then
    echo -e "${GREEN}[ok] Ansible: $(ansible --version | head -n1)${NC}"
else
    echo -e "${YELLOW}[--] Ansible not found (deploy.sh installs it automatically)${NC}"
fi

if command -v jq &> /dev/null; then
    echo -e "${GREEN}[ok] jq${NC}"
else
    echo -e "${YELLOW}[--] jq not found. Installing...${NC}"
    sudo apt update && sudo apt install -y jq
fi

if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    echo -e "${GREEN}[ok] SSH key: $(cat "$HOME/.ssh/id_ed25519.pub")${NC}"
    echo "     Make sure ssh_public_key in terraform/terraform.tfvars matches."
else
    echo -e "${YELLOW}[--] No SSH key at ~/.ssh/id_ed25519.pub${NC}"
    echo "     Generate one: ssh-keygen -t ed25519 -C 'k3s-cluster'"
fi

# Reachability check against the Proxmox host from terraform.tfvars
PVE_HOST=$(sed -n 's|.*proxmox_api_url.*https://\([^:/"]*\).*|\1|p' terraform/terraform.tfvars | head -n1)
if [ -n "${PVE_HOST}" ]; then
    echo -e "\n${GREEN}Testing Proxmox connectivity (${PVE_HOST})...${NC}"
    if ping -c 1 -W 2 "${PVE_HOST}" &> /dev/null; then
        echo -e "${GREEN}[ok] Proxmox host is reachable${NC}"
    else
        echo -e "${YELLOW}[--] Cannot ping ${PVE_HOST} (may be fine if ICMP is blocked)${NC}"
    fi
fi

echo -e "\n${YELLOW}Next steps:${NC}"
echo "1. Edit terraform/terraform.tfvars (API token secret, template, network)"
echo "2. Push any local manifest changes (nodes + Argo CD pull from git)"
echo "3. Run: ./deploy.sh"
