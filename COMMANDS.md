# K3s HA Cluster — Setup Guide

## Cluster topology

| Role          | Count | Notes                                       |
| ------------- | ----- | ------------------------------------------- |
| Control plane | 3     | kube-vip CP VIP: `172.16.69.50` (port 6443) |
| Worker        | 3     |                                             |

MetalLB manages LoadBalancer services (L2 mode):

| Service | Ports         | IP source               |
| ------- | ------------- | ----------------------- |
| Traefik | 80, 443, 2222 | MetalLB pool assignment |

## Component versions

| Component | Version              |
| --------- | -------------------- |
| K3s       | v1.32.3+k3s1         |
| kube-vip  | v0.8.7               |
| MetalLB   | v0.14.9              |
| kured     | v1.15.0              |
| KEDA      | v2.15.1              |
| Traefik   | v3.3.4               |
| Gitea     | 1.23.8 (chart ~12.5) |

---

## Prerequisites

- All nodes can reach each other.
- This repository is cloned to the same path on every node (e.g. `/opt/manifests`).
- Nodes run a supported Linux distro (Ubuntu 24.04 / Debian 12 recommended).
- `curl`, `helm`, `python3` available on the deploy host.
- Adjust `VIP`, `INTERFACE`, and version variables at the top of each script if needed.

---

## Step 1 — Bootstrap master1

```bash
# On master1, as root:
sudo bash install.sh
```

This script:

1. Copies the kube-vip static pod to `/var/lib/rancher/k3s/agent/pod-manifests/`
2. Installs K3s with `--cluster-init`
3. Applies RBAC and kured
4. Installs MetalLB and applies the IP pool configuration from `platform/metallb/`
5. Installs KEDA
6. Installs Longhorn distributed storage
7. Prints the join token and commands for the remaining nodes

Save the printed `NODE_TOKEN` — you need it for all other nodes.

---

## Step 2 — Join master2 and master3

```bash
# On master2 and master3, as root:
sudo K3S_TOKEN='<token-from-step-1>' bash scripts/02-join-control-plane.sh
```

Run this on each additional control plane node. Each will:

1. Copy the kube-vip static pod (control-plane HA only)
2. Join via the VIP `https://172.16.69.50:6443`

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

## Step 5 — Deploy applications

```bash
# On master1 (kubectl + helm must be available):
bash scripts/04-deploy-apps.sh
```

This script (no Flux, no GitOps controller):

1. Creates namespaces and generates secrets
2. Deploys cert-manager and Traefik via `kubectl apply -k`
3. Deploys Gitea via `helm upgrade --install` using `apps/gitea/values.yaml` (includes chart-managed PostgreSQL + Valkey)
4. Bootstraps the runner registration token and KEDA API token via Gitea's REST API
5. Deploys the runner `Deployment` and KEDA `ScaledObject` via `kubectl apply -k`

Runners start at **0 replicas** and scale up automatically when CI jobs are queued.

---

## Load Balancing Architecture

Responsibilities are split between two components:

| Component | Role                                             |
| --------- | ------------------------------------------------ |
| kube-vip  | Control-plane HA only (VIP 172.16.69.50:6443)    |
| MetalLB   | Service load balancing, assigns LoadBalancer IPs |

kube-vip is **not** involved in application traffic routing. MetalLB operates in L2 mode using ARP, which is compatible with Proxmox LAN environments.

**IP pool** (update `platform/metallb/ipaddresspool.yaml` to match your LAN):

```yaml
addresses:
  - 192.168.1.200-192.168.1.220
```

To apply pool changes:

```bash
kubectl apply -k platform/metallb/
```

---

## Updating platform components (Day-2)

```bash
# After changing anything under platform/:
bash scripts/06-sync-platform.sh
```

The script re-applies RBAC, kured, MetalLB config, KEDA, and Longhorn in order.

> **kube-vip exception** — it is a static pod, not managed by kubectl. If you change
> `platform/system/kube-vip.yaml`, copy it manually to each control plane node:
>
> ```bash
> cp platform/system/kube-vip.yaml /var/lib/rancher/k3s/agent/pod-manifests/kube-vip.yaml
> ```

## Secrets (Day-2)

```bash
# Update the Gitea OIDC provider credentials:
kubectl create secret generic gitea-oidc \
  --namespace gitea \
  --from-literal=key="<CLIENT_ID>" \
  --from-literal=secret="<CLIENT_SECRET>" \
  --from-literal=discoveryURL="<DISCOVERY_URL>" \
  --dry-run=client -o yaml | kubectl apply -f -

# Rotate the Anubis signing key (causes all active challenge cookies to expire):
kubectl create secret generic anubis-key \
  --namespace anubis \
  --from-literal=ED25519_PRIVATE_KEY_HEX="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/anubis -n anubis
```

---

## Updating application manifests (Day-2)

```bash
# Infrastructure manifests (networkpolicies, routes, etc.)
kubectl apply -k apps/gitea/
kubectl apply -k apps/gitea-runner/
kubectl apply -k apps/anubis/

# Gitea Helm chart upgrade (edit apps/gitea/values.yaml first)
helm upgrade gitea gitea/gitea \
  --namespace gitea \
  --version "~12.5" \
  --values apps/gitea/values.yaml \
  --timeout 15m --wait
```

---

## KEDA runner scaling

```bash
# Current replica count
kubectl get deployment gitea-runner -n gitea-runners

# KEDA status
kubectl get scaledobject -n gitea-runners
kubectl describe scaledobject gitea-runner -n gitea-runners

# Runner registration token
kubectl get secret gitea-runner-registration -n gitea-runners -o jsonpath='{.data.token}' | base64 -d

# KEDA API token
kubectl get secret gitea-api-token -n gitea-runners -o jsonpath='{.data.token}' | base64 -d
```

---

## kured reboot window

Edit [platform/system/kured.yaml](platform/system/kured.yaml) to change the maintenance window.

Default: Mon–Fri, 02:00–05:00 local time, checked every hour.

```bash
kubectl apply -k platform/system/
```

---

## Kubeconfig for local kubectl

```bash
# Copy kubeconfig to your local machine (replace <MASTER_IP> with any master's IP):
scp root@<MASTER_IP>:/etc/rancher/k3s/k3s.yaml ~/.kube/oict-config

# Update the server address to the VIP
sed -i 's|https://127.0.0.1:6443|https://172.16.69.50:6443|' ~/.kube/oict-config

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
