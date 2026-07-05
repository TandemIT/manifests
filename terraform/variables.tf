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

variable "vm_id_start" {
  description = "Starting VM ID for created VMs"
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

variable "gateway" {
  description = "Network gateway"
  type        = string
  default     = "172.16.69.1"
}

variable "nameserver" {
  description = "DNS nameserver"
  type        = string
  default     = "172.16.69.1"
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
  default     = "172.16.69.100"
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
  default     = "172.16.69.150"
}

variable "k3s_version" {
  description = "K3s version to install (the repo's manifests are pinned against v1.32.3+k3s1)"
  type        = string
  default     = "v1.32.3+k3s1"
}

variable "vip" {
  description = "Control-plane VIP announced by kube-vip (must be outside the node IP ranges and the MetalLB pool)"
  type        = string
  default     = "172.16.69.50"
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

# Passthrough only - not used by any resource here. Lets scripts/06-seal-secrets.sh
# read a local, gitignored input (this file) instead of prompting
# interactively, and supports any number of providers. Create the OAuth2
# provider/application for each one yourself (e.g. in Authentik, Keycloak,
# ...) and add an entry here, keyed by a short slug used in the secret name
# and Gitea's callback URL (/user/oauth2/<slug>/callback). Leave empty ({})
# to skip OIDC.
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

# Same passthrough pattern as gitea_oidc_providers, for Gitea's other
# built-in auth source type. Point this at an existing LDAP/AD server, or an
# Authentik LDAP outpost if you set one up - this repo does not create or
# manage either. Leave empty ({}) to skip LDAP.
variable "gitea_ldap_providers" {
  description = "Gitea LDAP login providers, keyed by slug"
  type = map(object({
    display_name             = string
    host                      = string
    port                      = number
    security_protocol         = optional(string, "LDAPS") # unencrypted | StartTLS | LDAPS
    bind_dn                   = string
    bind_password             = string
    user_search_base          = string
    user_filter               = string
    admin_filter              = optional(string, "")
    email_attribute           = optional(string, "mail")
    username_attribute        = optional(string, "uid")
    public_ssh_key_attribute  = optional(string, "")
  }))
  default   = {}
  sensitive = true
}
