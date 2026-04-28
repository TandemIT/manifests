# Open ICT — Self-Hosted GitOps Platform

> A production-ready, fully self-hosted Git service and CI/CD platform built on a 6-node K3s cluster.
> Infrastructure-as-code all the way down — every component declared, versioned, and reproducible.

[![K3s](https://img.shields.io/badge/K3s-v1.32.3-blue?logo=kubernetes)](https://k3s.io)
[![Traefik](https://img.shields.io/badge/Traefik-v3.3.4-blue?logo=traefikproxy)](https://traefik.io)
[![MetalLB](https://img.shields.io/badge/MetalLB-v0.14.9-orange)](https://metallb.universe.tf)
[![Gitea](https://img.shields.io/badge/Gitea-1.23.8-green?logo=gitea)](https://gitea.io)
[![cert-manager](https://img.shields.io/badge/cert--manager-v1.15.3-blue)](https://cert-manager.io)
[![KEDA](https://img.shields.io/badge/KEDA-v2.15.1-purple)](https://keda.sh)

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Cluster Topology](#cluster-topology)
- [IP Addressing](#ip-addressing)
- [Component Stack](#component-stack)
- [Design Decisions](#design-decisions)
- [Network Policy & Security](#network-policy--security)
- [CI/CD Autoscaling](#cicd-autoscaling)
- [Deployment](#deployment)
- [Repository Structure](#repository-structure)

---

## Overview

This repository contains all Kubernetes manifests needed to deploy and operate a self-hosted GitOps platform. The platform is built on a **6-node K3s cluster** (3 control-plane + 3 workers) and provides:

| Capability                 | Technology                             |
| -------------------------- | -------------------------------------- |
| Source control & Actions   | Gitea                                  |
| CI/CD execution            | Act Runner (GitHub Actions-compatible) |
| Autoscaling                | KEDA                                   |
| Ingress + TCP routing      | Traefik v3                             |
| TLS automation             | cert-manager + Let's Encrypt           |
| Load balancing             | MetalLB (L2/ARP mode)                  |
| Control-plane HA           | kube-vip (ARP)                         |
| Automated node maintenance | kured                                  |

Everything is managed through **Kustomize** with **Helm** used solely for the Gitea application chart. There is no GitOps controller (Flux/ArgoCD) — deployments are driven by idempotent shell scripts that wrap `kubectl` and `helm`.

---

## Architecture

```
                        ┌─────────────────────────────────────────────────┐
                        │                    LAN / Internet                │
                        └───────────────────────┬─────────────────────────┘
                                                 │
                              ┌──────────────────▼──────────────────┐
                              │    MetalLB VIP  172.16.69.60        │
                              │    (L2/ARP — announced on LAN)      │
                              └──────────────────┬──────────────────┘
                                                 │
                              ┌──────────────────▼──────────────────┐
                              │           Traefik  (2 replicas)     │
                              │   :80 (HTTP)  :443 (HTTPS)          │
                              │   :2222 (TCP — Git SSH)             │
                              └──────┬──────────────────┬───────────┘
                                     │  HTTP(S)          │ TCP/SSH
                          ┌──────────▼──────┐   ┌───────▼──────────┐
                          │  IngressRoute   │   │ IngressRouteTCP  │
                          │  git.open-ict.hu│   │  port 2222       │
                          └──────────┬──────┘   └───────┬──────────┘
                                     │                   │
                          ┌──────────▼───────────────────▼──────────┐
                          │                 Gitea (1 replica)        │
                          │           rootless · port 3000/22        │
                          └──────────┬──────────────────┬───────────┘
                                     │                   │
                       ┌─────────────▼──────┐ ┌─────────▼───────────────┐
                       │  PostgreSQL HA      │ │  Valkey Cluster         │
                       │  2 replicas        │ │  6 nodes (3M + 3R)      │
                       │  + 2 pgpool        │ │  hard anti-affinity      │
                       └────────────────────┘ └─────────────────────────┘

  ┌──────────────────────────────────────────────────────────────────────┐
  │  Control Plane HA                                                    │
  │                                                                      │
  │  kube-vip VIP  172.16.69.50:6443  (ARP)                             │
  │  ┌──────────┐  ┌──────────┐  ┌──────────┐                          │
  │  │ master1  │  │ master2  │  │ master3  │                           │
  │  └──────────┘  └──────────┘  └──────────┘                          │
  └──────────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────────────┐
  │  CI/CD Autoscaling (KEDA)                                            │
  │                                                                      │
  │  Gitea Job Queue ──► KEDA ScaledObject ──► Act Runner pods          │
  │  (poll every 15s)      min=2 / max=10      (dind sidecar)           │
  └──────────────────────────────────────────────────────────────────────┘
```

---

## Cluster Topology

| Node      | Role          | Description                                                  |
| --------- | ------------- | ------------------------------------------------------------ |
| `master1` | Control Plane | Cluster init node, bootstraps kube-vip + platform components |
| `master2` | Control Plane | Joins via VIP `172.16.69.50:6443`                            |
| `master3` | Control Plane | Joins via VIP `172.16.69.50:6443`                            |
| `worker1` | Worker        | Runs application workloads                                   |
| `worker2` | Worker        | Runs application workloads                                   |
| `worker3` | Worker        | Runs application workloads                                   |

The three control-plane nodes provide **etcd quorum** — the cluster tolerates the loss of one control-plane node without interruption. kube-vip floats the API VIP across whichever control-plane node is the current leader.

---

## IP Addressing

| Address        | Role                         | Component |
| -------------- | ---------------------------- | --------- |
| `172.16.69.50` | Control-plane VIP            | kube-vip  |
| `172.16.69.60` | Application LoadBalancer VIP | MetalLB   |

Both VIPs are announced via **ARP** (Layer 2), which works well on a flat LAN (e.g. Proxmox virtual network). Upstream routing is not required.

Pod-to-pod DNS resolution for `git.open-ict.hu` is solved with **hostAliases** injected directly into cert-manager and KEDA operator pods, pointing the hostname at the MetalLB VIP. This avoids a dependency on split-horizon DNS while keeping the Let's Encrypt HTTP-01 challenge and the KEDA runner-queue API working from inside the cluster.

---

## Component Stack

### Platform Layer

Deployed during cluster bootstrap via `scripts/01-bootstrap-first-master.sh`. These components are prerequisites for everything else.

| Component | Version      | Namespace        | Purpose                                              |
| --------- | ------------ | ---------------- | ---------------------------------------------------- |
| K3s       | v1.32.3+k3s1 | —                | Lightweight Kubernetes distribution                  |
| kube-vip  | v0.8.7       | `kube-system`    | Floating VIP for the Kubernetes API server           |
| MetalLB   | v0.14.9      | `metallb-system` | L2 load balancer for application services            |
| kured     | v1.15.0      | `kube-system`    | Automated rolling node reboot (weekdays 02:00–05:00) |
| KEDA      | v2.15.1      | `keda`           | Event-driven pod autoscaling                         |

### Application Layer

Deployed via `scripts/04-deploy-apps.sh`. Order matters — cert-manager must be ready before Gitea, Traefik must have its LoadBalancer IP before routes are created.

| Component      | Version | Namespace       | Purpose                                      |
| -------------- | ------- | --------------- | -------------------------------------------- |
| Traefik        | v3.3.4  | `traefik`       | Ingress controller + TCP proxy               |
| cert-manager   | v1.15.3 | `cert-manager`  | Automated TLS certificates via Let's Encrypt |
| Gitea          | 1.23.8  | `gitea`         | Self-hosted Git service with Actions support |
| PostgreSQL HA  | chart   | `gitea`         | Highly available database for Gitea          |
| Valkey Cluster | chart   | `gitea`         | Distributed cache and session store          |
| Act Runner     | 0.4.1   | `gitea-runners` | GitHub Actions-compatible CI/CD executor     |

---

## Design Decisions

### MetalLB over K3s ServiceLB

K3s ships with its own `ServiceLB` (formerly Klipper), which satisfies `LoadBalancer` services by running a hostPort DaemonSet on every node. It is functional but has a critical limitation: it cannot guarantee a **stable, single IP address** across the cluster. Different nodes can advertise the service at their own node IPs, which creates ambiguity and breaks DNS-based routing.

**MetalLB in L2 mode solves this cleanly:**

- A single virtual IP (`172.16.69.60`) is announced via ARP.
- The speaker pod that wins leader election holds the VIP; if that node goes down, a new speaker takes over and announces the VIP within seconds.
- Traefik's `LoadBalancer` service always resolves to one predictable IP, which is what DNS records and Let's Encrypt HTTP-01 challenges depend on.

K3s is launched with `--disable=servicelb` to remove the conflict.

---

### kube-vip for Control-Plane HA

kube-vip runs as a **static pod** on each control-plane node (placed directly into `/etc/kubernetes/manifests/` before K3s starts). It uses ARP-based leader election to float the VIP `172.16.69.50` across whichever control-plane node is currently healthy.

This is kept completely separate from MetalLB by design:

- kube-vip is responsible for **API server access** only — it never touches application traffic.
- MetalLB is responsible for **application LoadBalancer services** only.

Mixing the two responsibilities into one tool would make troubleshooting harder and couple the availability of `kubectl` access to the availability of your application IP pool.

---

### Traefik for SSH TCP Routing (Port 2222)

Gitea supports Git-over-SSH. Rather than exposing an additional LoadBalancer service (which would consume a second IP from the MetalLB pool), SSH traffic is routed through Traefik via a dedicated **TCP entrypoint on port 2222**.

The `IngressRouteTCP` resource in `apps/gitea/ingressroute-tcp.yaml` matches all traffic on that entrypoint using `HostSNI('*')` (TCP passthrough — no TLS inspection) and forwards it to the Gitea SSH service. From the user's perspective, their Git remote is simply `ssh://git.open-ict.hu:2222`.

This keeps the entire platform reachable through a single IP address.

---

### Traefik Non-Root Binding (Ports 8000/8443 vs 80/443)

Linux restricts binding to ports below 1024 to processes running as root. Traefik runs as UID `65532` (non-root). Rather than granting the `NET_BIND_SERVICE` capability, Traefik listens on high ports (`8000`, `8443`, `2222`) internally. The `LoadBalancer` service maps the standard external ports (`80`, `443`, `2222`) to these high internal ports via `targetPort`. No capabilities needed, no root required.

---

### PostgreSQL HA over a Single Instance

Gitea's data lives in PostgreSQL. A single-instance database is a hard availability boundary — if the pod restarts or the node is drained for maintenance, Gitea becomes unavailable until it recovers.

The PostgreSQL HA chart deploys:

- **2 PostgreSQL replicas** — one primary, one hot standby with streaming replication.
- **2 pgpool replicas** — connection pool and query router. pgpool handles failover promotion transparently; Gitea only ever connects to pgpool, never directly to a Postgres pod.

This means a PostgreSQL primary failure causes a brief pause while pgpool promotes the standby, after which Gitea automatically reconnects — rather than a full outage until a pod is rescheduled.

---

### Valkey Cluster for Caching

Valkey (a Redis-compatible fork) is deployed as a **6-node cluster**: 3 shards, each with a primary and a replica. All 6 pods have **hard pod anti-affinity** on `kubernetes.io/hostname`, meaning each must land on a different node.

With 6 nodes in a 6-node cluster (3 CP + 3 workers), this guarantees:

- No two Valkey pods share a node.
- The cluster can survive the loss of one shard's primary and still serve cache traffic from the remaining 4 nodes.
- A full node failure only takes down one shard, not the entire cache.

This is deliberately over-provisioned for a platform of this scale — the goal is to demonstrate cluster-aware placement and HA patterns.

---

### Ephemeral Runner Registration

Each Act Runner pod registers itself with Gitea on startup using a one-time registration token and deregisters on graceful shutdown. This means:

- Crashed or deleted pods do not leave zombie runner registrations behind in Gitea.
- New pods are always registered with a fresh identity — no stale state from previous runs.
- The runner registration token is generated by the bootstrap script via the Gitea API and stored as a Kubernetes `Secret`; it is never committed to this repository.

The termination grace period is set to **3660 seconds** (one hour plus one minute). This gives a running CI job a full hour to complete before the pod is force-killed during a rolling update or scale-down event.

---

### KEDA for Runner Autoscaling

The runner `Deployment` starts at **0 replicas**. KEDA watches the Gitea Actions job queue (via the `github-runner` trigger, which is Gitea-compatible) and scales the deployment based on queued job count:

| Condition         | Replicas                                                     |
| ----------------- | ------------------------------------------------------------ |
| No jobs queued    | 0 (or 2 if Gitea API is unreachable for 3 consecutive polls) |
| Jobs queued       | 1 runner per queued job, up to 10                            |
| Post-job cooldown | Scales back down after 120 seconds                           |

The **fallback minimum of 2** exists as a safety net: if the Gitea API is temporarily unreachable, KEDA switches to fallback mode and maintains a minimum 2 runners rather than scaling to zero, preventing jobs from getting stuck with no runner available.

---

## Network Policy & Security

All namespaces with application workloads have explicit `NetworkPolicy` resources. The default posture is **deny-all ingress and egress**, with specific allow rules for each required communication path.

### Gitea allowed traffic

| Direction | Peer                       | Ports    | Purpose                                 |
| --------- | -------------------------- | -------- | --------------------------------------- |
| Ingress   | `traefik` namespace        | 3000, 22 | HTTP and SSH from ingress controller    |
| Ingress   | `gitea-runners` namespace  | 3000     | Runner API calls                        |
| Ingress   | `keda` namespace           | 3000     | KEDA job-queue polling                  |
| Egress    | `gitea` namespace (pgpool) | 5432     | Database connections                    |
| Egress    | `gitea` namespace (valkey) | 6379     | Cache and session store                 |
| Egress    | External                   | 443, 25  | HTTPS outbound + SMTP for notifications |

### Pod security highlights

| Component    | UID   | Read-only rootfs      | Seccomp        | Capabilities                             |
| ------------ | ----- | --------------------- | -------------- | ---------------------------------------- |
| Traefik      | 65532 | Yes                   | RuntimeDefault | drop ALL                                 |
| cert-manager | 1000  | Yes                   | RuntimeDefault | drop ALL                                 |
| Gitea        | 1000  | No (writable app dir) | RuntimeDefault | drop ALL                                 |
| Act Runner   | 1000  | No                    | RuntimeDefault | drop ALL                                 |
| dind sidecar | root  | No                    | Unconfined     | SYS_ADMIN (required for mount/overlayfs) |

The dind sidecar is the only privileged workload and is unavoidable for Docker-in-Docker CI execution. It is isolated to the `gitea-runners` namespace and cannot reach the Gitea or platform namespaces except through the allowed network policy rules.

---

## CI/CD Autoscaling

```
  Gitea Actions job pushed
          │
          ▼
  KEDA polls Gitea API (every 15s)
  GET /api/v1/repos/.../actions/runners?status=queued
          │
          ▼
  ScaledObject computes desired replicas
  (1 runner per queued job, 0–10 range)
          │
          ▼
  Kubernetes scales the runner Deployment
          │
  Each new pod:
    init → register with Gitea API (gets runner token)
    main → act_runner daemon picks up jobs
    dind → Docker daemon on 127.0.0.1:2375
          │
  On scale-down (SIGTERM):
    act_runner drains current job (up to 3660s grace period)
    init → deregister from Gitea API
```

Supported job labels: `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-22.04`

---

## Deployment

> Full command reference is in [COMMANDS.md](COMMANDS.md).

### Prerequisites

- 6 Linux nodes reachable over SSH
- IP range `172.16.69.50–172.16.69.60` available on the LAN
- DNS record: `git.open-ict.hu` → `172.16.69.60`
- Internet access for pulling images and Let's Encrypt challenges

### Bootstrap order

```bash
# 1. Initialize the first control-plane node
bash scripts/01-bootstrap-first-master.sh

# 2. Join the remaining control-plane nodes (run on master2, master3)
bash scripts/02-join-control-plane.sh

# 3. Join worker nodes (run on worker1–3)
bash scripts/03-join-worker.sh

# 4. Deploy the application stack (run on master1)
bash scripts/04-deploy-apps.sh
```

Each script is idempotent. Re-running it will not duplicate resources. To tear down the application layer:

```bash
bash scripts/05-reset-apps.sh
```

### Secrets (never committed)

The bootstrap scripts generate and store the following as Kubernetes Secrets at deploy time:

| Secret               | Namespace                | Contents                        |
| -------------------- | ------------------------ | ------------------------------- |
| `gitea-admin`        | `gitea`                  | Gitea admin username + password |
| `gitea-runner-token` | `gitea-runners`          | Act Runner registration token   |
| `keda-gitea-token`   | `keda` / `gitea-runners` | Gitea API token for KEDA        |
| `gitea-postgresql`   | `gitea`                  | Database credentials            |

---

## Repository Structure & Contents

This repository is organized to provide a clear separation between platform infrastructure, application workloads, and operational scripts. Below is an overview of the major directories and files at the root level, along with their purposes:

### Root-Level Files

- **install.sh**: Entry point script for bootstrapping the first control-plane node. It sources the main bootstrap script and should be run on the initial master node.
- **COMMANDS.md**: Comprehensive command reference for all deployment and operational tasks.
- **README.md**: This documentation file.

### scripts/

Contains all automation scripts for cluster lifecycle management:

- **01-bootstrap-first-master.sh**: Initializes the first control-plane node and deploys core platform components.
- **02-join-control-plane.sh**: Used to join additional control-plane nodes to the cluster.
- **03-join-worker.sh**: Used to join worker nodes.
- **04-deploy-apps.sh**: Deploys the full application stack (Traefik, cert-manager, Gitea, etc.).
- **05-reset-apps.sh**: Removes all application workloads from the cluster.
- **lib-functions.sh**: Shared Bash functions used by other scripts.

### platform/

Holds all platform-level Kubernetes manifests and Kustomize overlays:

- **metallb/**: Configures MetalLB for L2 load balancing and IP address pool management.
- **system/**: Contains kube-vip static pod manifests for control-plane HA and kured for automated node reboots.
- **rbac/**: RBAC policies for system daemons and controllers.
- **keda/**: KEDA operator deployment and host alias patches for autoscaling.
- **configs/**: Additional platform configuration overlays.

### apps/

Contains application-specific Kubernetes manifests and Kustomize overlays:

- **traefik/**: Ingress controller configuration. The `base/` subdirectory includes deployment, service, RBAC, and IngressClass resources.
- **cert-manager/**: PKI automation for TLS certificates. Includes `base/` for upstream release and `issuers/` for Let's Encrypt ClusterIssuers.
- **gitea/**: Self-hosted Git service. Contains: - `values.yaml`: Helm chart values for Gitea deployment. - `ingressroute-tcp.yaml`: Traefik TCP route for SSH (port 2222). - `middleware.yaml`: Rate limiting and HTTPS redirect policies. - `networkpolicy*.yaml`: Network isolation for Gitea, PostgreSQL, and Valkey.
- **gitea-runner/**: CI/CD runner deployment. The `base/` subdirectory includes the runner Deployment, KEDA ScaledObject for autoscaling, and NetworkPolicy for isolation.
- **anubis/**: Example application with its own namespace, certificate, deployment, service, ingress, middleware, and network policies.

- **namespace.yaml**: Defines the Kubernetes namespace for the component.
- **deployment.yaml**: Describes the Deployment resource for running pods.
- **service.yaml**: Exposes the application internally or externally.
- **ingressroute.yaml / ingressroute-tcp.yaml**: Traefik-specific routing for HTTP(S) and TCP (SSH) traffic.
- **middleware.yaml**: Traefik middleware for rate limiting, redirects, etc.
- **networkpolicy.yaml**: Enforces network segmentation and security.
- **certificate.yaml**: Requests TLS certificates via cert-manager.
- **policy-configmap.yaml**: Stores policy configuration for apps.
- **kustomization.yaml**: Kustomize manifest for composing resources.
- **values.yaml**: Helm values for templated deployments (Gitea).

### Middleware

Middleware resources are defined in `middleware.yaml` files found in various application directories (e.g., `apps/gitea/middleware.yaml`, `apps/anubis/middleware.yaml`). These files configure Traefik middleware components such as:

- **Rate limiting**: Protects backend services from excessive requests.
- **HTTPS redirection**: Ensures all HTTP traffic is redirected to HTTPS.
- **Header manipulation**: Adds or modifies HTTP headers for security or compliance.

Each service can have its own middleware configuration, referenced by its IngressRoute or IngressRouteTCP resource. This modular approach allows for fine-grained traffic management and security policies per application.

- **namespace.yaml**: Defines the Kubernetes namespace for the component.
- **deployment.yaml**: Describes the Deployment resource for running pods.
- **service.yaml**: Exposes the application internally or externally.
- **ingressroute.yaml / ingressroute-tcp.yaml**: Traefik-specific routing for HTTP(S) and TCP (SSH) traffic.
- **middleware.yaml**: Traefik middleware for rate limiting, redirects, etc.
- **networkpolicy.yaml**: Enforces network segmentation and security.
- **certificate.yaml**: Requests TLS certificates via cert-manager.
- **policy-configmap.yaml**: Stores policy configuration for apps.
- **kustomization.yaml**: Kustomize manifest for composing resources.
- **values.yaml**: Helm values for templated deployments (Gitea).

---

## Tools & Frameworks Used

- **Kubernetes**: Container orchestration and workload management.
- **Kustomize**: Native Kubernetes configuration management and overlays.
- **Helm**: Used only for Gitea application deployment.
- **Traefik**: Ingress controller and TCP proxy for HTTP(S) and SSH traffic. Traefik's middleware system is used to implement rate limiting, HTTPS redirection, and header manipulation for enhanced security and traffic management.
- **cert-manager**: Automated TLS certificate management with Let's Encrypt.
- **MetalLB**: L2 load balancer for exposing services with stable IPs.
- **KEDA**: Event-driven autoscaling for CI/CD runners.
- **kube-vip**: Floating VIP for control-plane HA.
- **kured**: Automated node reboots for security updates.

## Architecture

### Traffic Management with Traefik Middleware

All ingress traffic is routed through Traefik, which leverages its middleware system to enforce security and operational policies. Middleware components are attached to IngressRoute and IngressRouteTCP resources to provide:

- **Rate limiting** to protect backend services from abuse
- **Automatic HTTP to HTTPS redirection** for secure access
- **Custom header injection and manipulation** for compliance and security

This approach ensures consistent, centralized traffic management across all applications and services deployed in the cluster.

- **Kubernetes**: Container orchestration and workload management.
- **Kustomize**: Native Kubernetes configuration management and overlays.
- **Helm**: Used only for Gitea application deployment.
- **Traefik**: Ingress controller and TCP proxy for HTTP(S) and SSH traffic.
- **cert-manager**: Automated TLS certificate management with Let's Encrypt.
- **MetalLB**: L2 load balancer for exposing services with stable IPs.
- **KEDA**: Event-driven autoscaling for CI/CD runners.
- **kube-vip**: Floating VIP for control-plane HA.
- **kured**: Automated node reboots for security updates.

---

## Installation & Configuration Notes

1. **Clone the repository to all nodes.**
2. **Run `install.sh` on the first control-plane node** to bootstrap the cluster and deploy platform components.
3. **Join additional control-plane and worker nodes** using the provided scripts in the `scripts/` directory.
4. **Deploy the application stack** with `scripts/04-deploy-apps.sh` after the platform is ready.
5. **Reset or tear down applications** with `scripts/05-reset-apps.sh` as needed.

All scripts are idempotent and safe to re-run. Secrets are generated at deploy time and stored as Kubernetes Secrets (never committed to the repo).

---

_Maintained by the Open ICT platform team — platform-ops@open-ict.hu_
