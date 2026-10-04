# Open ICT - self-hosted Git platform on K3s

Gitea with Actions runners on a K3s cluster of Proxmox VMs, run GitOps-style:
OpenTofu creates the VMs, Ansible runs the bootstrap scripts, and Argo CD
reconciles everything else from this repository. Operational commands are in
[COMMANDS.md](COMMANDS.md).

## Architecture

- **Nodes:** 3 control-plane + 3 worker VMs by default (`terraform/variables.tf`). kube-vip announces the API VIP `172.16.10.50:6443` via ARP.
- **Edge:** MetalLB (L2) gives Traefik the public IP `145.89.192.138` (ports 80, 443, 2222) and announces it on `public0`, a second NIC with no address on the public VLAN. An nftables guard on `public0` admits only those ports (plus some ICMP) to that IP, and replies are policy-routed back out through `public_gateway`. `git.open-ict.hu` goes through Anubis to Gitea, except that clients in `145.89.192.0/24` and `172.16.0.0/12` bypass Anubis. SSH on 2222 goes straight to Gitea. `argo.git.open-ict.hu` is limited to RFC1918 sources.
- **Gitea:** one replica, PostgreSQL HA (2 nodes + 2 pgpool), and a 6-pod Valkey cluster. LFS, packages, Actions artifacts, attachments, avatars and archives go to Garage (3-replica S3). Git repositories stay on Gitea's PVC.
- **Runners:** a fixed 5-replica Deployment with a privileged dind sidecar. Each pod registers ephemerally on start and uses act_runner's default labels.
- **Two layers:** `platform/` (MetalLB, the CoreDNS override, and the kube-vip static-pod template) is applied once by `scripts/01`, outside Argo CD. Everything else is an Argo CD Application in `argocd/apps/` (app-of-apps).
- **Secrets:** none are in git. Random secrets are created by `scripts/01`. Runtime tokens (runner registration, Garage S3 keys) are minted by in-cluster bootstrap Jobs. OIDC/LDAP credentials come from `terraform/terraform.tfvars` through `scripts/06-auth-providers.sh`.
- **Self-maintenance:** unattended-upgrades installs OS updates, and kured reboots one node at a time (Mon-Fri 02:00-05:00). system-upgrade-controller applies K3s patch releases on the pinned minor channel (Mon-Fri 05:30-07:00). Three backup CronJobs upload to Garage nightly.

## Components

| Component | Version | Pinned in |
|---|---|---|
| K3s | v1.32.3+k3s1 (then patch upgrades on the v1.32 channel) | `terraform/variables.tf`, `scripts/01..03`, `apps/system-upgrade-controller/` |
| kube-vip | v0.8.7 | `platform/system/kube-vip.yaml` |
| MetalLB | v0.14.9 | `platform/metallb/kustomization.yaml` |
| Argo CD | v3.4.4 | `argocd/install/kustomization.yaml` |
| KEDA | v2.15.1 (installed, no consumer yet) | `apps/keda/kustomization.yaml` |
| kured | 1.15.0 | `apps/kured/kustomization.yaml` |
| system-upgrade-controller | v0.20.1 | `apps/system-upgrade-controller/kustomization.yaml` |
| Traefik | v3.3.4 (chart 34.4.1) | `argocd/apps/traefik.yaml`, `apps/traefik/values.yaml` |
| cert-manager | v1.15.3 (chart) | `argocd/apps/cert-manager.yaml` |
| Gitea | 1.27.3 (chart 12.7.0: postgresql-ha 16.3.2, valkey-cluster 3.0.24) | `argocd/apps/gitea.yaml`, `apps/gitea/values.yaml` |
| Garage | v1.0.0 | `apps/garage/statefulset.yaml` |
| Anubis | v1.27.0 | `apps/anubis/deployment.yaml` |
| Gitea runner | 3.5.0 | `apps/gitea-runner/deployment.yaml` |

## Prerequisites

- A Proxmox API token and an Ubuntu cloud-image template with **qemu-guest-agent preinstalled**. Terraform waits for the agent.
- A Debian/Ubuntu deploy host with an SSH key and `python3`. `setup.sh` installs OpenTofu, kubectl and jq if they're missing, and `deploy.sh` installs Ansible.
- Free LAN addresses for the VIP (`172.16.10.50`) and the nodes (defaults `172.16.10.100-102` and `172.16.10.150-152`).
- A public VLAN on the Proxmox bridge that carries `145.89.192.138`, and its router (`public_vlan_tag` and `public_gateway` in `terraform.tfvars`). DNS records `git.open-ict.hu` and `argo.git.open-ict.hu` must point at that IP.
- Internet access from the nodes for images and Let's Encrypt HTTP-01.

## Setup

Nodes and Argo CD pull from GitHub (`TandemIT/manifests`, `master`), not from
your checkout: **push before you deploy**.

### Automated (Proxmox)

```bash
./setup.sh                        # checks/installs prerequisites, creates terraform/terraform.tfvars
# edit terraform/terraform.tfvars, then push
export TF_VAR_vm_password='...'   # cloud-init user password, min 12 chars; never in tfvars
./deploy.sh
```

`deploy.sh` is non-interactive and safe to re-run. In order, it:

1. Runs `tofu apply` (or `terraform` if tofu is missing; override with `TF_BIN=`). This creates the VMs and renders `ansible/inventory.yml`.
2. Waits for SSH on every node.
3. Runs `ansible/system-utils-install.yml`: qemu-guest-agent, micro, unattended-upgrades, and the `public0` NIC (netplan, nftables guard, rp_filter).
4. Runs `ansible/k3s-install.yml`. It clones the repo to `/opt/manifests` on every node, runs `scripts/01` on the first control plane, `02` on the other control planes one at a time, and `03` on the workers. It then writes `./kubeconfig`, pointed at the VIP.
5. Runs `scripts/06-auth-providers.sh` to push the OIDC/LDAP secrets.
6. Waits up to 20 minutes for every Argo CD Application to be Synced and Healthy.

### Manual (any 6 Linux nodes)

Clone the repo on every node, then run as root:

```bash
sudo bash install.sh                                            # first control plane (runs scripts/01); prints the join token
sudo K3S_TOKEN='<token>' bash scripts/02-join-control-plane.sh  # each other control plane, one at a time
sudo K3S_TOKEN='<token>' bash scripts/03-join-worker.sh         # each worker
```

`VIP`, `K3S_VERSION` and `VIP_INTERFACE` (default: the default-route
interface) can be overridden through the environment. Afterwards, run
`bash scripts/06-auth-providers.sh` from a host that has the kubeconfig,
`terraform/terraform.tfvars` and a `tofu -chdir=terraform init`.

### What happens next

`scripts/01` installs K3s with `--cluster-init` (bundled Traefik and ServiceLB
disabled). It then applies `platform/`, creates the bootstrap secrets,
installs Argo CD, and applies `argocd/root-app.yaml`. Argo CD syncs
`argocd/apps/` in waves:

| Wave | Applications |
|---|---|
| 0 | `argocd` (self-management) |
| 1 | `keda`, `kured`, `system-upgrade-controller` |
| 2 | `traefik`, `cert-manager` |
| 3 | `cert-manager-issuers` |
| 4 | `anubis`, `gitea-config` |
| 5 | `garage`: its bootstrap Job mints the S3 credentials Gitea needs |
| 6 | `gitea` |
| 7 | `gitea-runner`: its bootstrap Job mints the registration token |

## Repository layout

```
terraform/   Proxmox VMs + generated ansible/inventory.yml (OpenTofu, local state)
ansible/     node utilities; drives scripts/01..03 (no install logic of its own)
scripts/     01 bootstrap, 02/03 join, 05 reset apps, 06 auth providers, lib-functions.sh
platform/    network foundation, applied by scripts/01 (not Argo CD)
argocd/      install/ (Argo CD itself), root-app.yaml, apps/ (one Application per component)
apps/        manifests and Helm values per component
```

## Known limitations

- MetalLB announces only on `public0` (`platform/metallb/l2advertisement.yaml`). Terraform always creates it, but with manual setup you have to create `public0` yourself, or the public IP is never announced.
- The public NIC reaches only new or rebuilt VMs, because `network` is in `ignore_changes`. VMs created before it existed get no `public0`, and Ansible skips them.
- Every PVC uses K3s `local-path`. Volumes are pinned to one node, can't be expanded in place, and aren't replicated at the storage level.
- PostgreSQL HA has two nodes and no witness, so a network partition between them has no arbiter.
- The PostgreSQL, pgpool and Valkey images are the chart defaults from `bitnamilegacy/*`, which is frozen and gets no security updates.
- Valkey has no password. Only `apps/gitea/networkpolicy-valkey.yaml` isolates it.
- NetworkPolicies select specific pods, and there is no namespace-wide default-deny.
- No backup has been restore-tested.
- Objects written to the Gitea PVC before Garage storage was configured were not migrated.
- Runner autoscaling is waiting on an upstream KEDA Gitea scaler (see `apps/gitea-runner/scaledobject.yaml`).
- The Argo CD allowlist covers all of RFC1918 until the VPN CIDR is known (`argocd/install/ip-allowlist.yaml`).
- Terraform state is local, and `terraform/terraform.tfvars` is the only copy of the OIDC/LDAP credentials. Back both up.
