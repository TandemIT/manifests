# K3s HA Cluster — Setup Guide

## Cluster topology

| Role          | Count | Notes                                       |
| ------------- | ----- | ------------------------------------------- |
| Control plane | 3     | kube-vip CP VIP: `172.16.10.50` (port 6443) |
| Worker        | 3     |                                             |

MetalLB manages LoadBalancer services (L2 mode):

| Service | Ports         | IP source               |
| ------- | ------------- | ----------------------- |
| Traefik | 80, 443, 2222 | MetalLB pool assignment |

## Component versions

| Component | Version              |
| --------- | -------------------- |
| K3s       | v1.32.3+k3s1 (installed; system-upgrade-controller then tracks the v1.32 channel) |
| kube-vip  | v0.8.7               |
| MetalLB   | v0.14.9              |
| kured     | v1.15.0              |
| system-upgrade-controller | v0.20.1 |
| KEDA      | v2.15.1              |
| Traefik   | v3.3.4 (chart 34.4.1) |
| Gitea     | 1.27.3 (chart 12.7.0) |
| cert-manager | v1.15.3 (chart)   |

---

## Prerequisites

- All nodes can reach each other.
- This repository is cloned to the same path on every node (e.g. `/opt/manifests`).
- Nodes run a supported Linux distro (Ubuntu 24.04 / Debian 12 recommended).
- `curl`, `python3` and `kubectl` available on the deploy host (`./setup.sh` installs kubectl).
- Override `VIP` / `K3S_VERSION` via environment variables if needed; the
  kube-vip network interface is auto-detected from the default route
  (override with `VIP_INTERFACE`).

---

## Step 0 — Zero-touch alternative (OpenTofu/Terraform + Ansible)

If the nodes are Proxmox VMs, the whole flow below (including VM creation) is
automated:

```bash
./setup.sh    # prereq check; creates terraform/terraform.tfvars from the example
# edit terraform/terraform.tfvars, push local commits, then:
./deploy.sh
```

`deploy.sh` provisions the VMs, generates `ansible/inventory.yml` from the
Terraform variables, runs `scripts/01..03` on the right nodes via Ansible,
fetches a kubeconfig (pointed at the VIP) to the repo root, and waits for the
Argo CD applications to converge. Right after Ansible it pushes the Gitea
OIDC/LDAP credentials from `terraform.tfvars` (`scripts/06-auth-providers.sh`).
Steps 1–4 below are the manual equivalent; run that script yourself after them.

---

## Step 1 — Bootstrap master1

```bash
# On master1, as root:
sudo bash install.sh
```

This script:

1. Copies the kube-vip static pod to `/var/lib/rancher/k3s/agent/pod-manifests/`
2. Installs K3s with `--cluster-init`
3. Applies the network foundation from `platform/` (MetalLB + IP pool, CoreDNS override) — directly via `kubectl apply -k`, outside Argo CD
4. Generates the bootstrap secrets
5. Installs Argo CD and applies the root app-of-apps — from here Argo CD deploys everything else (KEDA, kured, Traefik, cert-manager, Gitea, ...)
6. Prints the join token and commands for the remaining nodes

Save the printed `NODE_TOKEN` — you need it for all other nodes.

---

## Step 2 — Join master2 and master3

```bash
# On master2 and master3, as root:
sudo K3S_TOKEN='<token-from-step-1>' bash scripts/02-join-control-plane.sh
```

Run this on each additional control plane node. Each will:

1. Copy the kube-vip static pod (control-plane HA only)
2. Join via the VIP `https://172.16.10.50:6443`

---

## Step 3 — Join workers (worker1, worker2, worker3)

```bash
# On each worker node, as root:
sudo K3S_TOKEN='<token-from-step-1>' bash scripts/03-join-worker.sh
```

---

## Step 4 — Verify the cluster

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# All 6 nodes should appear as Ready
kubectl get nodes -o wide

# kube-vip should be running on every control plane node (CP HA only)
kubectl get pods -n kube-system | grep kube-vip

# MetalLB controller and speakers should be running
kubectl get pods -n metallb-system

# Verify IP pool is configured
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system

# kured
kubectl get pods -n kube-system -l name=kured

# KEDA
kubectl get pods -n keda
```

---

## Step 5 — Applications deploy themselves

No further manual step. Step 1 already installed Argo CD and applied the root
app-of-apps (`argocd/root-app.yaml`), which reconciles every Application in
`argocd/apps/` from git — cert-manager, Traefik, Anubis, Garage, Gitea
(Helm chart + values from this repo), and the runner stack, in sync-wave
order. Runtime credentials that Argo CD cannot invent (Garage's S3 keys, the
runner registration token) are minted automatically by
in-cluster bootstrap Jobs (`apps/garage/job-bootstrap.yaml`,
`apps/gitea-runner/job-bootstrap-tokens.yaml`) the first time each app syncs.

Watch convergence:

```bash
kubectl get applications -n argocd -w
```

Runners run as a fixed 5-replica Deployment; KEDA autoscaling is pending an upstream KEDA release (see [Runner scaling](#runner-scaling)).

---

## Load Balancing Architecture

Responsibilities are split between two components:

| Component | Role                                             |
| --------- | ------------------------------------------------ |
| kube-vip  | Control-plane HA only (VIP 172.16.10.50:6443)    |
| MetalLB   | Service load balancing, assigns LoadBalancer IPs |

kube-vip is **not** involved in application traffic routing. MetalLB operates in L2 mode using ARP, which is compatible with Proxmox LAN environments.

**IP pool** (`platform/metallb/ipaddresspool.yaml` — a single public address):

```yaml
addresses:
  - 145.89.192.138-145.89.192.138
```

To apply pool changes:

```bash
kubectl apply -k platform/metallb/
```

---

## Updating platform components (Day-2)

The network foundation under `platform/` is deliberately **not** managed by
Argo CD — it defines the cluster's addresses and is applied imperatively so it
can be tuned and verified without self-heal interfering:

```bash
# After changing anything under platform/ (MetalLB pool, CoreDNS override):
kubectl apply -k platform/
```

Everything else (KEDA, kured, Traefik, ...) is reconciled by Argo CD — just
commit and push.

> **kube-vip exception** — it is a static pod, not managed by kubectl. If you change
> `platform/system/kube-vip.yaml`, re-render it on each control plane node with the
> same interface/VIP rewrite the bootstrap scripts apply (a plain `cp` would keep
> the template's `eth0`):
>
> ```bash
> IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
> sed -e "s|value: eth0|value: ${IFACE}|" \
>     -e "s|value: \"172.16.10.50\"|value: \"${VIP:-172.16.10.50}\"|" \
>   platform/system/kube-vip.yaml > /var/lib/rancher/k3s/agent/pod-manifests/kube-vip.yaml
> ```

## Secrets (Day-2)

No secret is stored in git. Two sources:

- **Random, generated once** by `scripts/01-bootstrap-first-master.sh`
  (`gitea-admin`, both PostgreSQL secrets, `garage-rpc`, `anubis-key`, runner
  placeholders). Never overwritten by a re-run.
- **Chosen by you** in `terraform/terraform.tfvars` (`gitea_oidc_providers`,
  `gitea_ldap_providers`), pushed by `scripts/06-auth-providers.sh`.

```bash
# Add/change/remove an OIDC or LDAP provider: edit terraform.tfvars, then
bash scripts/06-auth-providers.sh
# commit + push apps/gitea/values-oidc.yaml / values-ldap.yaml if it says they
# changed, then restart Gitea so it re-reads the credentials:
kubectl rollout restart deployment/gitea -n gitea

# Rotate the Anubis signing key (causes all active challenge cookies to expire):
kubectl delete secret anubis-key -n anubis
kubectl create secret generic anubis-key -n anubis \
  --from-literal=ED25519_PRIVATE_KEY_HEX="$(openssl rand -hex 32)"
kubectl rollout restart deployment/anubis -n anubis
```

Runtime tokens are **not** in git — they are minted in-cluster by bootstrap
Jobs (`runner-token-bootstrap` in gitea-runners, `garage-bootstrap` in
garage). To re-mint, delete the secret and the Job, then let Argo CD sync:

```bash
kubectl delete secret gitea-runner-registration -n gitea-runners
kubectl delete job runner-token-bootstrap -n gitea-runners
```

---

## Updating application manifests (Day-2)

Every app under `apps/` (Gitea's infrastructure manifests, the runner stack,
Anubis, Garage, ...) is synced by Argo CD with `selfHeal: true` — a manual
`kubectl apply` against one of these directories is either redundant (Argo CD
reapplies the same content on its next sync) or gets reverted by self-heal if
it diverges from git. Edit the manifest, commit, push:

```bash
git add apps/gitea-runner/ && git commit -m "..." && git push
kubectl get application gitea-runner -n argocd -w   # watch it sync
```

To force an immediate sync instead of waiting for Argo CD's poll interval,
use the `argocd` CLI (https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_sync/):

```bash
argocd app sync <name>
```

Gitea, Traefik, and cert-manager are deployed from their official Helm charts
by Argo CD (multi-source apps: chart from the upstream repo, values from this
repo). Upgrading any of them = bump `targetRevision` in the matching
`argocd/apps/*.yaml`, edit the `apps/<name>/values.yaml` if needed, commit, push.

To preview what a Kustomize directory would render without applying it:

```bash
kubectl kustomize apps/gitea-runner/
```

---

## Runner scaling

The runners are a fixed `replicas: 5` Deployment. KEDA autoscaling is
**pending** an upstream KEDA Gitea runner scaler release
([kedacore/keda#8087](https://github.com/kedacore/keda/pull/8087)); the
prepared config is commented out in `apps/gitea-runner/scaledobject.yaml`,
which also holds the enablement checklist.

```bash
# Current replica count
kubectl get deployment gitea-runner -n gitea-runners

# Runner registration token
kubectl get secret gitea-runner-registration -n gitea-runners -o jsonpath='{.data.token}' | base64 -d

# Once KEDA autoscaling is enabled:
kubectl get scaledobject -n gitea-runners
kubectl describe scaledobject gitea-runner -n gitea-runners
kubectl get secret gitea-api-token -n gitea-runners -o jsonpath='{.data.token}' | base64 -d
```

---

## kured reboot window

Edit [apps/kured/reboot-window-patch.yaml](apps/kured/reboot-window-patch.yaml) to change the maintenance window (the DaemonSet itself is the pinned upstream release manifest — this patch is the only local override).

Default: Mon–Fri, 02:00–05:00 local time, checked every hour.

kured is managed by Argo CD (the `kured` Application) — commit and push, and
it reconciles automatically.

---

## Kubeconfig for local kubectl

```bash
# Copy kubeconfig to your local machine (replace <MASTER_IP> with any master's IP):
scp root@<MASTER_IP>:/etc/rancher/k3s/k3s.yaml ~/.kube/oict-config

# Update the server address to the VIP
sed -i 's|https://127.0.0.1:6443|https://172.16.10.50:6443|' ~/.kube/oict-config

export KUBECONFIG=~/.kube/oict-config
kubectl get nodes
```

---

## Uninstall

```bash
# On server nodes:
/usr/local/bin/k3s-uninstall.sh

# On worker nodes:
/usr/local/bin/k3s-agent-uninstall.sh
```
