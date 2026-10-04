variable "proxmox_api_url" {
  description = "Proxmox API URL"
  type        = string
  default     = "https://<YOUR_PROXMOX_HOST>:8006/api2/json"
}

variable "proxmox_api_token_id" {
  description = "Proxmox API Token ID (format: user@realm!tokenname)"
  type        = string
  default     = "root@pam!terraform"
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API Token Secret"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
  default     = "YOUR_SSH_PUBLIC_KEY_HERE"
}

variable "vm_password" {
  description = "Password for the cloud-init user (ubuntu) on every VM - set via TF_VAR_vm_password"
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = length(var.vm_password) >= 12
    error_message = "vm_password must be at least 12 characters."
  }
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "proxmox"
}

variable "template_id" {
  description = "VM template name for cloning"
  type        = string
  default     = "ubuntu-24.04-cloud-tpl"
}

# A clone does not inherit the template's cicustom (the provider clears it),
# so a vendor snippet set on the template never runs unless passed here.
variable "cloudinit_vendor_snippet" {
  description = "Cloud-init vendor snippet for new VMs, e.g. local:snippets/ubuntu-noble.yaml (empty = none)"
  type        = string
  default     = ""
}

variable "vm_id_start" {
  description = "First VM ID: control-plane nodes get vm_id_start+i, workers vm_id_start+100+i"
  type        = number
  default     = 30000
}

variable "storage" {
  description = "Storage pool for VM disks"
  type        = string
  default     = "local-zfs"
}

variable "bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "vlan_tag" {
  description = "VLAN tag on the VMs' network interface (0 = untagged)"
  type        = number
  default     = 0
}

variable "gateway" {
  description = "Network gateway"
  type        = string
  default     = "172.16.10.1"
}

variable "nameserver" {
  description = "DNS nameserver"
  type        = string
  default     = "172.16.10.1"
}

variable "searchdomain" {
  description = "DNS search domain"
  type        = string
  default     = "local"
}

variable "control_plane_count" {
  description = "Number of control plane nodes (3 for etcd quorum / kube-vip HA)"
  type        = number
  default     = 3

  validation {
    condition     = var.control_plane_count >= 1 && var.control_plane_count <= 100
    error_message = "control_plane_count must be 1-100 (workers' VM IDs start at vm_id_start+100)."
  }
}

variable "control_plane_cpu" {
  description = "CPU cores for control plane nodes"
  type        = number
  default     = 2
}

variable "control_plane_memory" {
  description = "Memory in MB for control plane nodes"
  type        = number
  default     = 4096
}

variable "control_plane_disk_size" {
  description = "Disk size for control plane nodes"
  type        = string
  default     = "10G"
}

variable "control_plane_ip_start" {
  description = "Starting IP for control plane nodes"
  type        = string
  default     = "172.16.10.100"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "worker_cpu" {
  description = "CPU cores for worker nodes"
  type        = number
  default     = 1
}

variable "worker_memory" {
  description = "Memory in MB for worker nodes"
  type        = number
  default     = 2048
}

variable "worker_disk_size" {
  description = "Disk size for worker nodes"
  type        = string
  default     = "10G"
}

variable "worker_ip_start" {
  description = "Starting IP for worker nodes"
  type        = string
  default     = "172.16.10.150"
}

variable "k3s_version" {
  description = "K3s version to install (system-upgrade-controller then applies patch releases)"
  type        = string
  default     = "v1.32.3+k3s1"
}

variable "vip" {
  description = "Control-plane VIP announced by kube-vip (must be outside the node IP ranges and the MetalLB pool)"
  type        = string
  default     = "172.16.10.50"
}

variable "manifests_repo" {
  description = "Git URL of this repository - cloned onto the nodes and pulled by Argo CD. Push local changes before deploying!"
  type        = string
  default     = "https://github.com/TandemIT/manifests.git"
}

variable "manifests_revision" {
  description = "Branch/tag of the manifests repository to deploy"
  type        = string
  default     = "master"
}

# Not referenced by any resource or output, so it never lands in state;
# scripts/06-auth-providers.sh reads it via `console`. The slug is used in the
# Secret name and Gitea's callback URL (/user/oauth2/<slug>/callback).
variable "gitea_oidc_providers" {
  description = "Gitea OIDC login providers, keyed by slug"
  type = map(object({
    display_name  = string
    client_id     = string
    client_secret = string
    discovery_url = string
    icon_url      = optional(string, "")
  }))
  default   = {}
  sensitive = true
}

# Same pattern as gitea_oidc_providers.
variable "gitea_ldap_providers" {
  description = "Gitea LDAP login providers, keyed by slug"
  type = map(object({
    display_name             = string
    host                     = string
    port                     = number
    security_protocol        = optional(string, "LDAPS") # unencrypted | StartTLS | LDAPS
    bind_dn                  = string
    bind_password            = string
    user_search_base         = string
    user_filter              = string
    admin_filter             = optional(string, "")
    email_attribute          = optional(string, "mail")
    username_attribute       = optional(string, "uid")
    public_ssh_key_attribute = optional(string, "")
  }))
  default   = {}
  sensitive = true
}
