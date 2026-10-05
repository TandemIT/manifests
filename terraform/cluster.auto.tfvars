# Non-sensitive cluster settings, committed (the GitHub repo is public).
# Credentials stay out of git: terraform.tfvars locally (gitignored),
# Actions secrets in CI (.gitea/workflows/deploy.yml). OpenTofu loads
# *.auto.tfvars after terraform.tfvars, so never set a key in both.

# Proxmox Connection
proxmox_api_url = "https://git.oicloud.local:8006/api2/json"

# The VM password is NOT set here: export TF_VAR_vm_password before deploy.sh.

# Public key for ubuntu@ on every VM (cloud-init): the deploy host's key and,
# in CI, the pair of the SSH_PRIVATE_KEY secret. Only new VMs pick up a change.
ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK8PCTetpKZbk4yPeC8nkgGN2LcBXlhGCUMKV6hZkxuj oracle@wsl-k3s-deploy"

# Proxmox Settings
# NOTE: agent = 1 in main.tf makes tofu wait for qemu-guest-agent. The
# template's image lacks it; the vendor snippet installs it on first boot.
cloudinit_vendor_snippet = "local:snippets/ubuntu-resolute.yaml"

proxmox_node    = "git"
template_id     = "ubuntu-resolute-template" # VMID 8201, Ubuntu 26.04 (by name; 8200 = 24.04)
vm_id_start     = 200                        # control plane: 200..; workers: 300..
storage         = "SAN-STORAGE"              # lvmthin, ~1.9 TB free (thin: sizes below are caps)
bridge          = "vmbr2"                    # EXTRANET, VLAN-aware
vlan_tag        = 10                         # 172.16.10.0/24
public_vlan_tag = 0                          # untagged: VLAN 5 is the switch port's native VLAN. 2nd NIC, no address; MetalLB announces 145.89.192.138 on it
public_gateway  = "145.89.192.1"             # router on VLAN 5: replies to public connections go back via it
gateway         = "172.16.10.1"
nameserver      = "172.16.10.1"
searchdomain    = "local"

# Control Plane Configuration (3 nodes for etcd quorum + kube-vip HA)
control_plane_count = 3
# Host: 1x Xeon Gold 5415+ (16 threads), 251 GB RAM. CPU is the scarce
# resource; RAM and (thin) disk are not. Control-plane nodes are untainted,
# so they run workloads too and need disk for images + local-path PVCs.
control_plane_cpu       = 2
control_plane_memory    = 8192
control_plane_disk_size = "50G"
control_plane_ip_start  = "172.16.10.100"

# Worker Configuration
worker_count = 5
# Grow by raising worker_count (own VMID range: adding never replaces).
# Disk: Garage alone claims 3x50Gi local-path, plus Gitea/Postgres PVCs,
# images and runner builds.
worker_cpu       = 4
worker_memory    = 16384
worker_disk_size = "150G"
worker_ip_start  = "172.16.10.150"

# K3s Configuration
# The manifests in this repo are pinned/tested against v1.32.3+k3s1.
k3s_version = "v1.32.3+k3s1"

# Control-plane VIP (kube-vip). Keep outside the node ranges. The MetalLB
# pool (platform/metallb/ipaddresspool.yaml) is a separate, external public
# address, not part of this LAN range.
vip = "172.16.10.50"

# Where the nodes + Argo CD pull the manifests from. Local commits must be
# pushed here before deploying.
manifests_repo     = "https://github.com/TandemIT/manifests.git"
manifests_revision = "master"
