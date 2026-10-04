output "control_plane_ips" {
  description = "Control plane node IP addresses"
  value       = local.control_plane_ips
}

output "worker_ips" {
  description = "Worker node IP addresses"
  value       = local.worker_ips
}

output "control_plane_names" {
  description = "Control plane node names"
  value       = [for vm in proxmox_vm_qemu.k3s_control_plane : vm.name]
}

output "worker_names" {
  description = "Worker node names"
  value       = [for vm in proxmox_vm_qemu.k3s_worker : vm.name]
}

output "ssh_command_control_plane" {
  description = "SSH command for control plane node"
  value       = "ssh ubuntu@${cidrhost(local.control_plane_network, local.control_plane_start_host)}"
}

output "kubeconfig_command" {
  description = "Command to retrieve kubeconfig from control plane"
  value       = "ssh ubuntu@${cidrhost(local.control_plane_network, local.control_plane_start_host)} 'sudo cat /etc/rancher/k3s/k3s.yaml'"
}

output "cluster_info" {
  description = "K3s cluster information"
  value = {
    control_plane = {
      count  = var.control_plane_count
      cpu    = var.control_plane_cpu
      memory = var.control_plane_memory
      ips    = local.control_plane_ips
    }
    workers = {
      count  = var.worker_count
      cpu    = var.worker_cpu
      memory = var.worker_memory
      ips    = local.worker_ips
    }
    k3s_version = var.k3s_version
    vip         = var.vip
  }
}