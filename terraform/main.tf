terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc10"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}

provider "proxmox" {
  pm_api_url          = var.proxmox_api_url
  pm_api_token_id     = var.proxmox_api_token_id
  pm_api_token_secret = var.proxmox_api_token_secret
  pm_tls_insecure     = true
  pm_log_enable       = true
  pm_log_file         = "terraform-plugin-proxmox.log"
  pm_log_levels = {
    _default    = "debug"
    _capturelog = ""
  }
}

# The K3s cluster token is NOT generated here: k3s mints its own node-token
# on the first master, and Ansible slurps it for the join plays.

locals {
  control_plane_network    = "${join(".", slice(split(".", var.control_plane_ip_start), 0, 3))}.0/24"
  control_plane_start_host = tonumber(element(split(".", var.control_plane_ip_start), 3))

  worker_network    = "${join(".", slice(split(".", var.worker_ip_start), 0, 3))}.0/24"
  worker_start_host = tonumber(element(split(".", var.worker_ip_start), 3))

  control_plane_ips = [
    for i in range(var.control_plane_count) :
    cidrhost(local.control_plane_network, local.control_plane_start_host + i)
  ]
  worker_ips = [
    for i in range(var.worker_count) :
    cidrhost(local.worker_network, local.worker_start_host + i)
  ]
}

resource "proxmox_vm_qemu" "k3s_control_plane" {
  count = var.control_plane_count

  name        = "k3s-cp-${count.index + 1}"
  tags        = "k3s;control-plane" # metadata only: never replaces or reboots
  target_node = var.proxmox_node
  clone       = var.template_id
  full_clone  = true
  vmid        = var.vm_id_start + count.index

  agent   = 1
  os_type = "cloud-init"
  memory  = var.control_plane_memory
  bios    = "ovmf"
  machine = "q35"

  cpu {
    type    = "host"
    cores   = var.control_plane_cpu
    sockets = 1
  }
  scsihw = "virtio-scsi-pci"
  # Explicit: a clone otherwise inherits the template's boot order, which
  # usually points at scsi0 rather than the virtio0 disk defined below.
  boot = "order=virtio0"

  start_at_node_boot = true
  # Explicit (vm_state is deprecated; unset it diffs "running" -> null).
  power_state = "running"

  # Never reboot on apply: with count, every affected VM would reboot at the
  # same time (whole cluster down). Changes that need a reboot are applied as
  # pending and reported as a warning; reboot the nodes one at a time
  # (drain -> reboot -> uncordon).
  automatic_reboot          = false
  automatic_reboot_severity = "warning"

  startup_shutdown {
    order = 1
  }

  efidisk {
    storage = var.storage
  }

  disks {
    virtio {
      virtio0 {
        disk {
          storage = var.storage
          size    = var.control_plane_disk_size
        }
      }
    }
    scsi {
      scsi1 {
        cloudinit {
          storage = var.storage
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = var.bridge
    tag    = var.vlan_tag
  }

  # Console access
  serial {
    id   = 0
    type = "socket"
  }

  ipconfig0 = "ip=${cidrhost(local.control_plane_network, local.control_plane_start_host + count.index)}/24,gw=${var.gateway}"

  nameserver   = var.nameserver
  searchdomain = var.searchdomain

  # Vendor data merges with the ciuser/ipconfig0/... settings below.
  cicustom = var.cloudinit_vendor_snippet == "" ? null : "vendor=${var.cloudinit_vendor_snippet}"

  ciuser     = "ubuntu"
  cipassword = var.vm_password
  sshkeys    = var.ssh_public_key

  # clone/full_clone/vmid/efidisk/cicustom changes force a destroy+create of the VM
  # (provider ForceNew), which with count hits every node at once. They only
  # matter at creation: a new template applies to newly added nodes, and
  # existing nodes are rebuilt deliberately, one at a time
  # (tofu apply -replace='proxmox_vm_qemu.k3s_worker[0]').
  lifecycle {
    ignore_changes = [
      clone,
      full_clone,
      vmid,
      efidisk,
      cicustom,
      network,
      ciuser,
      sshkeys,
    ]
  }
}

resource "proxmox_vm_qemu" "k3s_worker" {
  count = var.worker_count

  name        = "k3s-worker-${count.index + 1}"
  tags        = "k3s;worker" # metadata only: never replaces or reboots
  target_node = var.proxmox_node
  clone       = var.template_id
  full_clone  = true
  # Own range, independent of control_plane_count: deriving it from that
  # count shifted (= replaced) every worker when a control-plane node was added.
  vmid = var.vm_id_start + 100 + count.index

  agent   = 1
  os_type = "cloud-init"
  memory  = var.worker_memory
  bios    = "ovmf"
  machine = "q35"

  cpu {
    type    = "host"
    cores   = var.worker_cpu
    sockets = 1
  }
  scsihw = "virtio-scsi-pci"
  # Explicit: a clone otherwise inherits the template's boot order, which
  # usually points at scsi0 rather than the virtio0 disk defined below.
  boot = "order=virtio0"

  start_at_node_boot = true
  # Explicit (vm_state is deprecated; unset it diffs "running" -> null).
  power_state = "running"

  # Never reboot on apply: with count, every affected VM would reboot at the
  # same time (whole cluster down). Changes that need a reboot are applied as
  # pending and reported as a warning; reboot the nodes one at a time
  # (drain -> reboot -> uncordon).
  automatic_reboot          = false
  automatic_reboot_severity = "warning"

  startup_shutdown {
    order = 2
  }

  efidisk {
    storage = var.storage
  }

  disks {
    virtio {
      virtio0 {
        disk {
          storage = var.storage
          size    = var.worker_disk_size
        }
      }
    }
    scsi {
      scsi1 {
        cloudinit {
          storage = var.storage
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = var.bridge
    tag    = var.vlan_tag
  }

  # Console access
  serial {
    id   = 0
    type = "socket"
  }

  ipconfig0 = "ip=${cidrhost(local.worker_network, local.worker_start_host + count.index)}/24,gw=${var.gateway}"

  nameserver   = var.nameserver
  searchdomain = var.searchdomain

  # Vendor data merges with the ciuser/ipconfig0/... settings below.
  cicustom = var.cloudinit_vendor_snippet == "" ? null : "vendor=${var.cloudinit_vendor_snippet}"

  ciuser     = "ubuntu"
  cipassword = var.vm_password
  sshkeys    = var.ssh_public_key

  # clone/full_clone/vmid/efidisk/cicustom changes force a destroy+create of the VM
  # (provider ForceNew), which with count hits every node at once. They only
  # matter at creation: a new template applies to newly added nodes, and
  # existing nodes are rebuilt deliberately, one at a time
  # (tofu apply -replace='proxmox_vm_qemu.k3s_worker[0]').
  lifecycle {
    ignore_changes = [
      clone,
      full_clone,
      vmid,
      efidisk,
      cicustom,
      network,
      ciuser,
      sshkeys,
    ]
  }
}

# Render the Ansible inventory from the same variables that created the VMs,
# so IPs, VIP, and the K3s version have a single source of truth. deploy.sh
# runs the playbooks against this generated file.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory.yml"
  file_permission = "0644"

  # Address checks live here because this resource depends on every IP; a
  # failed precondition fails the whole plan, so no VM is touched.
  lifecycle {
    precondition {
      condition     = local.control_plane_start_host + var.control_plane_count - 1 <= 254 && local.worker_start_host + var.worker_count - 1 <= 254
      error_message = "A node IP range runs past .254 of its /24: lower the count or the *_ip_start."
    }
    precondition {
      condition     = length(setintersection(local.control_plane_ips, local.worker_ips)) == 0
      error_message = "control_plane_ip_start + control_plane_count overlaps the worker range (worker_ip_start + worker_count)."
    }
    precondition {
      condition     = !contains(concat(local.control_plane_ips, local.worker_ips), var.vip)
      error_message = "vip falls inside a node IP range."
    }
    precondition {
      condition     = !contains(concat(local.control_plane_ips, local.worker_ips), var.gateway)
      error_message = "gateway falls inside a node IP range."
    }
  }
  content = join("\n", [
    "# GENERATED BY TERRAFORM (local_file.ansible_inventory) - do not edit.",
    yamlencode({
      all = {
        vars = {
          ansible_user = "ubuntu"
          # /dev/null known_hosts: rebuilt VMs reuse IPs with new host keys.
          ansible_ssh_common_args = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
          k3s_version             = var.k3s_version
          k3s_vip                 = var.vip
          manifests_repo          = var.manifests_repo
          manifests_revision      = var.manifests_revision
        }
      }
      k3s_cluster = {
        children = {
          control_plane = {
            hosts = {
              for i, ip in local.control_plane_ips :
              "k3s-cp-${i + 1}" => { ansible_host = ip }
            }
          }
          workers = {
            hosts = {
              for i, ip in local.worker_ips :
              "k3s-worker-${i + 1}" => { ansible_host = ip }
            }
          }
        }
      }
    })
  ])
}