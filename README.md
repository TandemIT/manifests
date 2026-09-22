# Open ICT — Self-Hosted GitOps Platform

> A production-ready, fully self-hosted Git service and CI/CD platform built on a 6-node K3s cluster.
> Infrastructure-as-code all the way down — every component declared, versioned, and reproducible.

[![K3s](https://img.shields.io/badge/K3s-v1.32.3-blue?logo=kubernetes)](https://k3s.io)
[![Traefik](https://img.shields.io/badge/Traefik-v3.3.4-blue?logo=traefikproxy)](https://traefik.io)
[![MetalLB](https://img.shields.io/badge/MetalLB-v0.14.9-orange)](https://metallb.universe.tf)
[![Gitea](https://img.shields.io/badge/Gitea-1.27.3-green?logo=gitea)](https://gitea.io)
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

Everything is managed through **Kustomize** with **Helm** used solely for the Gitea application chart. The cluster is split into two ownership layers:

- **Network foundation (`platform/`)** — kube-vip, MetalLB + IP pool, and the CoreDNS override. This layer defines the cluster's addresses and is applied imperatively by `scripts/01-bootstrap-first-master.sh` (`kubectl apply -k platform/`), *not* by Argo CD. That keeps it verifiable before GitOps starts and tunable without self-heal reverting changes; day-2 changes are a re-run of the same apply.
- **Everything above it** — driven by **Argo CD** using the app-of-apps pattern: the bootstrap script installs Argo CD and applies the root Application (`argocd/root-app.yaml`); KEDA, kured, Traefik, cert-manager, Gitea, runners, and Garage are reconciled from git via the Applications in `argocd/apps/`.

The shell scripts only cover what a GitOps controller cannot do: node bootstrap, the network foundation, secret generation, and one-time runtime initialization (runner tokens, Garage layout).

---

## Architecture

```
                        ┌─────────────────────────────────────────────────┐
                        │                    LAN / Internet                │
                        └───────────────────────┬─────────────────────────┘
                                                 │
                              ┌──────────────────▼──────────────────┐
                              │    MetalLB VIP  145.89.192.138      │
                              │    (L2/ARP — external public IP)    │
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
  │  kube-vip VIP  172.16.10.50:6443  (ARP)                             │
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
| `master2` | Control Plane | Joins via VIP `172.16.10.50:6443`                            |
| `master3` | Control Plane | Joins via VIP `172.16.10.50:6443`                            |
| `worker1` | Worker        | Runs application workloads                                   |
| `worker2` | Worker        | Runs application workloads                                   |
| `worker3` | Worker        | Runs application workloads                                   |

The three control-plane nodes provide **etcd quorum** — the cluster tolerates the loss of one control-plane node without interruption. kube-vip floats the API VIP across whichever control-plane node is the current leader.

---

## IP Addressing

| Address        | Role                         | Component |
| -------------- | ---------------------------- | --------- |
| `172.16.10.50`   | Control-plane VIP            | kube-vip  |
| `145.89.192.138` | Application LoadBalancer VIP | MetalLB   |

The control-plane VIP is announced via **ARP** (Layer 2) on the internal LAN (e.g. Proxmox virtual network); upstream routing is not required for `kubectl` access. The MetalLB VIP is a public IP bound directly to the node uplink, also announced via L2/ARP, so it is externally reachable without a separate NAT or port-forward hop.

Pod-to-pod DNS resolution for `git.open-ict.hu` is solved with **hostAliases** injected directly into cert-manager and KEDA operator pods, pointing the hostname at the MetalLB VIP. This avoids a dependency on split-horizon DNS while keeping the Let's Encrypt HTTP-01 challenge and the KEDA runner-queue API working from inside the cluster.

---

## Component Stack

### Platform Layer (bootstrap-owned, outside Argo CD)

Installed by `scripts/01-bootstrap-first-master.sh`: K3s and kube-vip on the node itself, then the network foundation from `platform/` via `kubectl apply -k`, then Argo CD. Manifests live in git and the apply is idempotent — declarative, just not continuously reconciled.

| Component | Version      | Namespace        | Purpose                                    |
| --------- | ------------ | ---------------- | ------------------------------------------ |
| K3s       | v1.32.3+k3s1 | —                | Lightweight Kubernetes distribution        |
| kube-vip  | v0.8.7       | `kube-system`    | Floating VIP for the Kubernetes API server |
| MetalLB   | v0.14.9      | `metallb-system` | L2 load balancer for application services  |
| Argo CD   | v3.4.4       | `argocd`         | GitOps controller — reconciles this repo   |

### Application Layer (Argo CD-managed)

Deployed by Argo CD via the Applications in `argocd/apps/`. Ordering is encoded as sync waves — KEDA CRDs before the runner ScaledObject, cert-manager CRDs before the issuers, Garage before Gitea (Gitea's pod references Garage-minted S3 credentials), Gitea before the runners. The network foundation (MetalLB VIP) already exists from bootstrap, so Traefik's LoadBalancer IP is available from the first sync. `scripts/04-deploy-apps.sh` remains as the script-driven alternative and as the runtime-initialization reference (runner tokens, Garage layout).

| Component                 | Version | Namespace        | Purpose                                                        |
| -------------------------- | ------- | ---------------- | --------------------------------------------------------------- |
| KEDA                       | v2.15.1 | `keda`           | Event-driven pod autoscaling                                    |
| kured                      | v1.15.0 | `kube-system`    | Automated rolling node reboot (weekdays 02:00–05:00)            |
| system-upgrade-controller  | v0.20.1 | `system-upgrade` | Automated K3s binary upgrades (weekdays 05:30–07:00)            |
| sealed-secrets             | v2.17.4 | `kube-system`    | Encrypts secrets so they're safe to commit to git                |
| Traefik                    | v3.3.4  | `traefik`        | Ingress controller + TCP proxy — 2 replicas, PDB enabled        |
| cert-manager               | v1.15.3 | `cert-manager`   | Automated TLS certificates via Let's Encrypt                    |
| Gitea                      | 1.27.3  | `gitea`          | Self-hosted Git service with Actions support                    |
| PostgreSQL HA              | chart 16.3.2 ⚠ | `gitea`   | HA database for Gitea — PDB and existingSecret from chart       |
| Valkey Cluster             | chart   | `gitea`          | Distributed cache and session store — PDB from chart default    |
| Act Runner                 | 3.5.0   | `gitea-runners`  | Gitea Actions CI/CD executor (gitea/runner, formerly act_runner), ResourceQuota-capped |
| Garage                     | v1.0.0  | `garage`         | Self-hosted S3-compatible object storage for Gitea + backups    |
| Anubis                     | v1.27.0 | `anubis`         | Bot-challenge reverse proxy in front of Gitea (`apps/anubis/`)  |

**Anubis** was pinned this audit from a floating `ghcr.io/techarohq/anubis:latest` tag to the exact `v1.27.0` release, and `imagePullPolicy` changed from `Always` to `IfNotPresent` to match — checked against Anubis's own build workflow first (`:latest` only ever moves on a non-pre-release tag push, never a main-branch commit or a `-pre` tag, so it could never have resolved to a pre-release build; the real risk pinning addresses is drift across stable releases over time, not accidental pre-release adoption). Anubis runs a single replica with `store.backend: memory` (`apps/anubis/policy-configmap.yaml`) — confirmed correct against Anubis's own store interface, which documents in-memory as explicitly non-persistent and reserved for single-process use; `valkey`/`s3api` backends exist and are real if Anubis is ever scaled beyond one replica, but there's no such requirement today, so nothing was added.

**Act Runner** was upgraded this audit from `gitea/act_runner:0.4.1` (deprecated Docker Hub path) to `gitea/runner:3.5.0` — the project's current name; the runner binary inside the image is also now `gitea-runner`, not `act_runner` (`apps/gitea-runner/deployment.yaml`).

⚠ **PostgreSQL HA and Valkey Cluster — urgent, unresolved, systemic to both.** The `postgresql-ha` (`16.3.2`) and `valkey-cluster` (`3.0.24`) chart versions this repo pins (via `apps/gitea/values.yaml` → the Gitea chart's own `Chart.yaml` dependency pins) default to `docker.io/bitnami/postgresql-repmgr:17.6.0-debian-12-r2` and `docker.io/bitnami/valkey-cluster:8.1.3-debian-12-r3` respectively for their actual StatefulSets. As of this audit, Docker Hub's own listing for **both** images states: *"This image is no longer available for free through Docker Hub... available as a built OCI artifact... through a commercial subscription of Bitnami Secure Images."* This is not the backup job (fixed above) — these are the live database and cache server images, and a pod reschedule that needs to re-pull either (new node, image eviction, etc.) may fail outright without a paid subscription's registry credentials. This needs a deliberate decision, not a silent fix: pay for Bitnami Secure Images, mirror/cache the images before they become unpullable, or migrate off Bitnami charts entirely for one or both (e.g. CloudNativePG or Zalando's postgres-operator for Postgres; a non-Bitnami Valkey/Redis chart for cache). Left unchanged pending that decision — this affects the actual data-plane, not something to fix silently mid-audit.

Garage (`apps/garage/`, `argocd/apps/garage.yaml`) is a first-class platform service in its own right, not a Gitea subcomponent — it serves Gitea's object storage today and is free to gain other consumers later. See [Gitea Object Storage on Garage](#gitea-object-storage-on-garage).

---

## Design Decisions

### MetalLB over K3s ServiceLB

K3s ships with its own `ServiceLB` (formerly Klipper), which satisfies `LoadBalancer` services by running a hostPort DaemonSet on every node. It is functional but has a critical limitation: it cannot guarantee a **stable, single IP address** across the cluster. Different nodes can advertise the service at their own node IPs, which creates ambiguity and breaks DNS-based routing.

**MetalLB in L2 mode solves this cleanly:**

- A single virtual IP (`145.89.192.138`) is announced via ARP.
- The speaker pod that wins leader election holds the VIP; if that node goes down, a new speaker takes over and announces the VIP within seconds.
- Traefik's `LoadBalancer` service always resolves to one predictable IP, which is what DNS records and Let's Encrypt HTTP-01 challenges depend on.

K3s is launched with `--disable=servicelb` to remove the conflict.

---

### kube-vip for Control-Plane HA

kube-vip runs as a **static pod** on each control-plane node (placed directly into `/etc/kubernetes/manifests/` before K3s starts). It uses ARP-based leader election to float the VIP `172.16.10.50` across whichever control-plane node is currently healthy.

This is kept completely separate from MetalLB by design:

- kube-vip is responsible for **API server access** only — it never touches application traffic.
- MetalLB is responsible for **application LoadBalancer services** only.

Mixing the two responsibilities into one tool would make troubleshooting harder and couple the availability of `kubectl` access to the availability of your application IP pool.

---

### Automatic OS Updates (unattended-upgrades + Kured)

`ansible/system-utils-install.yml` installs and configures `unattended-upgrades` on every node (control-plane and worker alike — nothing here needs them to differ). Security updates and normal package updates — including the kernel — are applied automatically; `ansible/templates/50unattended-upgrades.j2` allowlists the `-security` and `-updates` origins.

Reboots are deliberately **not** unattended-upgrades' job. `Unattended-Upgrade::Automatic-Reboot` and `Automatic-Reboot-WithUsers` are explicitly set to `false` (not left at whatever the packaged default happens to be), so a kernel update only leaves the standard `/var/run/reboot-required` sentinel behind. Kured (`apps/kured/`) already watches exactly that file — it bind-mounts the host's `/var/run` at `/sentinel` and points `--reboot-sentinel` at `/sentinel/reboot-required` — and reboots one node at a time inside its own maintenance window (weekdays 02:00–05:00). The flow is:

```
apt security/normal updates (unattended-upgrades)
        ↓
kernel/library update leaves /var/run/reboot-required
        ↓
Kured sees the sentinel, cordons + drains, reboots — one node at a time, only inside its window
```

One scheduler decides *what* to install; one scheduler decides *when* to reboot. Neither can reboot on its own outside that split.

---

### Traefik for SSH TCP Routing (Port 2222)

Gitea supports Git-over-SSH. Rather than exposing an additional LoadBalancer service (which would consume a second IP from the MetalLB pool), SSH traffic is routed through Traefik via a dedicated **TCP entrypoint on port 2222**.

The `IngressRouteTCP` resource in `apps/gitea/ingressroute-tcp.yaml` matches all traffic on that entrypoint using `HostSNI('*')` (TCP passthrough — no TLS inspection) and forwards it to the Gitea SSH service. From the user's perspective, their Git remote is simply `ssh://git.open-ict.hu:2222`.

This keeps the entire platform reachable through a single IP address.

---

### Traefik Non-Root Binding (Ports 8000/8443 vs 80/443)

Linux restricts binding to ports below 1024 to processes running as root. Traefik runs as UID `65532` (non-root). Rather than granting the `NET_BIND_SERVICE` capability, Traefik listens on high ports (`8000`, `8443`, `2222`) internally. The `LoadBalancer` service maps the standard external ports (`80`, `443`, `2222`) to these high internal ports via `targetPort`. No capabilities needed, no root required.

---

### Traefik `externalTrafficPolicy: Local` (real client source IPs)

MetalLB runs in L2 mode (`platform/metallb/`). With the Kubernetes default `externalTrafficPolicy: Cluster`, a packet that MetalLB's speaker announces on one node can be forwarded by kube-proxy to a Traefik pod on a *different* node — and that hop SNATs the packet, replacing the real client address with a node IP. Traefik's Service (`apps/traefik/values.yaml`) sets `externalTrafficPolicy: Local` instead, which keeps traffic on the node that received it and preserves the true client source IP. This is what makes IP-based access control meaningful anywhere in the cluster — the `ClientIP()` match in `apps/anubis/ingressroute.yaml` and the `rfc1918-allowlist` Middleware in `argocd/install/` both depend on it; without `Local`, both would frequently see a node address instead of the real caller.

---

### Argo CD Ingress + Network Restriction

Argo CD is reachable at `argo.git.open-ict.hu`, using the same Traefik + cert-manager pattern as every other app (`argocd/install/certificate.yaml`, `ingressroute.yaml`, `middleware.yaml`): a `Certificate` issued by `letsencrypt-prod`, terminated at Traefik. `argocd/install/argocd-cmd-params-cm-patch.yaml` sets `server.insecure: "true"` so `argocd-server` serves plain HTTP internally instead of its own self-signed TLS — the standard Argo CD pattern for ingress controllers that terminate TLS themselves rather than passing it through.

Access is additionally restricted by the `rfc1918-allowlist` Middleware (`argocd/install/ip-allowlist.yaml`), which allows all of `10.0.0.0/8`, `172.16.0.0/12`, and `192.168.0.0/16` and denies everything else. This is intentionally the entire private address space, not a specific VPN subnet — the VPN this will eventually be scoped to is still being built. That file is the single place these CIDRs are declared; when the VPN CIDR is final, replace the three ranges there and nothing else needs to change. Authentication is unchanged: the bootstrap-generated `argocd-initial-admin-secret` password (see [Secrets](#secrets-never-committed)) is still the only credential.

---

### PostgreSQL HA over a Single Instance

Gitea's data lives in PostgreSQL. A single-instance database is a hard availability boundary — if the pod restarts or the node is drained for maintenance, Gitea becomes unavailable until it recovers.

The PostgreSQL HA chart deploys:

- **2 PostgreSQL replicas** — one primary, one hot standby with streaming replication.
- **2 pgpool replicas** — connection pool and query router. pgpool handles failover promotion transparently; Gitea only ever connects to pgpool, never directly to a Postgres pod.

This means a PostgreSQL primary failure causes a brief pause while pgpool promotes the standby, after which Gitea automatically reconnects — rather than a full outage until a pod is rescheduled.

**Credentials**: `postgresql-ha.global.postgresql.existingSecret` / `...pgpool.existingSecret` in `apps/gitea/values.yaml` point at `postgresql-ha-credentials` and `postgresql-ha-pgpool-credentials` — sealed the same way as `gitea-admin` (see [Secrets](#secrets-never-committed)) — rather than the chart's own published default passwords.

**Drain protection**: both `postgresql-ha.postgresql.pdb` and `postgresql-ha.pgpool.pdb` default to `create: true` in the chart itself (`maxUnavailable: 1` each) and are not overridden here, so a PodDisruptionBudget already exists for both without needing to be declared in this repo's values.

**Quorum**: with exactly 2 PostgreSQL replicas, a *network partition* between them (not a clean node death, which repmgr handles via promotion) has no arbiter. The chart supports a dedicated `witness` node for this; adding one is an open operator decision — not implemented, since it's a real resource-cost tradeoff this repo has not stated an intent on.

---

### Valkey Cluster for Caching

Valkey (a Redis-compatible fork) is deployed as a **6-node cluster**: 3 shards, each with a primary and a replica. All 6 pods have **hard pod anti-affinity** on `kubernetes.io/hostname`, meaning each must land on a different node.

With 6 nodes in a 6-node cluster (3 CP + 3 workers), this guarantees:

- No two Valkey pods share a node.
- The cluster can survive the loss of one shard's primary and still serve cache traffic from the remaining 4 nodes.
- A full node failure only takes down one shard, not the entire cache.

This is deliberately over-provisioned for a platform of this scale — the goal is to demonstrate cluster-aware placement and HA patterns.

**No password (`usePassword: false`)** is the Gitea chart's own explicit default for this deployment mode, not an oversight — Valkey's isolation instead depends entirely on `apps/gitea/networkpolicy-valkey.yaml` restricting access to Gitea pods only. Do not treat this as safe to copy elsewhere without the same NetworkPolicy in place.

A PodDisruptionBudget (`maxUnavailable: 1` across all 6 pods) also comes from the `valkey-cluster` chart's own default (`pdb.create: true`), not from anything in this repo.

---

### Storage: local-path, its limits, and what moved to Garage

Every PVC in this cluster (Gitea, PostgreSQL, Valkey, Garage itself) is bound by K3s's default `local-path` provisioner — there is no other StorageClass in this repo. That means each PV is pinned by `nodeAffinity` to the node it was first created on (a pod cannot move with its data to another node), has no online expansion (raising a chart's `size:` does not resize an existing PVC), and has no storage-level replication or snapshotting of its own.

This is accepted as-is rather than "fixed" with an unproven CSI addition: PostgreSQL and Valkey compensate at the application layer (independent replicas on independent disks, not a shared volume), and Gitea's LFS/Packages/Actions-artifact growth — the data most likely to outgrow a fixed-size local PVC — now goes to Garage instead (below). A real fix for the underlying limitation (a replicated/CSI-backed StorageClass) is a separate infrastructure migration this repo does not have evidence to justify yet, and is not something `size:` bumps or new manifests here can substitute for.

### Gitea Object Storage on Garage

Gitea's `[storage]` app.ini section (`apps/gitea/values.yaml` → `gitea.config.storage`) points LFS, Packages, Actions artifacts/logs, attachments, avatars and repo-archive at Garage (`apps/garage/` — shared platform storage) — each of those derives from `[storage]` automatically unless it sets its own `STORAGE_TYPE` (none do). **Git repository data itself is not part of this and stays on the PVC** — Gitea has no S3 backend for raw repository storage.

The Garage bootstrap Job (`apps/garage/job-bootstrap.yaml`) mints a `gitea-storage` bucket and key, and writes the resulting credentials as `garage-gitea-storage-credentials` in the `gitea` namespace (cross-namespace RBAC in `apps/gitea/rbac-garage-bootstrap.yaml`, same pattern as `apps/gitea/rbac-runner-bootstrap.yaml`). Gitea consumes them via `gitea.additionalConfigFromEnvs` (`GITEA__STORAGE__MINIO_*` env vars from a `secretKeyRef`), never as plaintext in `gitea.config`.

**This does not migrate existing data.** Any LFS objects, packages, or artifacts already written to the PVC before this was configured stay there; only new writes go to Garage. A one-time migration (copying `data/lfs`, `data/packages`, etc. into the new bucket and confirming Gitea reads them back) is a separate, deliberate operation — not performed automatically by this config change.

### Terraform/OpenTofu State

Gitea 1.27.3 has a native Terraform State Registry (`backend "http"`, confirmed against the pinned version's actual source — not assumed from current docs): state upload/fetch, versioning by serial number, and locking (`POST`/`DELETE` on a `/lock` sub-route) are all built in, gated by the same `gitea.config.packages.ENABLED` flag already set above — no extra Gitea config, and no separate Garage bucket, since state data flows through the same `[storage]` → `gitea-storage` bucket as LFS/Packages.

No Terraform/OpenTofu workflow in this repo currently uses it — this repo's own cluster-provisioning `terraform/` uses local state, and no other backend configuration exists anywhere. If a future Gitea Actions workflow needs remote state, it authenticates with a Gitea personal access token (`write:package` scope) stored as a Gitea Actions secret, not a long-lived S3 credential:

```hcl
terraform {
  backend "http" {
    address        = "http://gitea-http.gitea.svc.cluster.local:3000/api/packages/{owner}/terraform/state/{name}"
    lock_address   = "http://gitea-http.gitea.svc.cluster.local:3000/api/packages/{owner}/terraform/state/{name}/lock"
    unlock_address = "http://gitea-http.gitea.svc.cluster.local:3000/api/packages/{owner}/terraform/state/{name}/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    username       = "{gitea-username}"
    password       = "{personal-access-token}"
  }
}
```

Use a private-visibility owner (user or org) for `{owner}` — Gitea's package permission model follows repo/org visibility, and this is not anonymous-safe on a public one.

**Backup gap**: like the rest of the Garage-backed Gitea storage above, state data is **not** covered by either backup CronJob below — `cronjob-backup-postgresql.yaml` only dumps the Postgres database (package/state *metadata*, not the state file content), and `cronjob-backup-gitea-data.yaml` only tars the Gitea PVC, not the Garage `gitea-storage` bucket. This is an existing, pre-dating gap (also true for LFS/Packages/Actions artifacts), not something introduced by moving Terraform state here — flagged, not fixed, as part of this change.

### Backups

`apps/gitea/cronjob-backup-postgresql.yaml` and `apps/gitea/cronjob-backup-gitea-data.yaml` run daily, dumping/tarring to a dedicated Garage `platform-backups` bucket (credentials: `garage-backups-credentials`, minted the same way as the Gitea storage credentials above):

- **PostgreSQL**: `pg_dump` against pgpool, gzipped, uploaded as `postgresql/gitea-<timestamp>.sql.gz`. 14-day retention, pruned by the same CronJob. Its `pg_dump` client image was switched this audit from `bitnamilegacy/postgresql:17` (Docker Hub's frozen "no longer updated" registry) to the actively-maintained Docker Official Image `postgres:17.11` — same major version as the actual server (17.6.0, below), pg_dump is compatible across patch releases of a major version.
- **Gitea repository data**: tars `data/git`, `data/gitea/conf`, and `data/gitea/gitea.db`-adjacent state from the Gitea PVC (mounted read-only, scheduled onto the same node as the Gitea pod since local-path is node-pinned), gzipped, uploaded as `gitea-data/gitea-data-<timestamp>.tar.gz`. Same 14-day retention.

This is **replication ≠ backup**: PostgreSQL's streaming replication and Valkey's cluster replicas protect against a node dying, not against a bad migration, an accidental deletion, or logical corruption, which replicate to every copy just as faithfully as legitimate writes. Neither CronJob has been exercised as a restore yet — treat that as required before relying on either in an incident. Restore procedure:

```bash
# PostgreSQL: download the latest dump, then restore into a scratch database first
aws --endpoint-url http://garage.garage.svc.cluster.local:3900 s3 cp \
  s3://platform-backups/postgresql/gitea-<timestamp>.sql.gz - | gunzip | \
  psql -h <pgpool-service> -U postgres -d gitea_restore_test

# Gitea data: download and inspect into a scratch path before ever touching the live PVC
aws --endpoint-url http://garage.garage.svc.cluster.local:3900 s3 cp \
  s3://platform-backups/gitea-data/gitea-data-<timestamp>.tar.gz - | tar -tzv | head
```

---

### Ephemeral Runner Registration

Each Act Runner pod registers itself with Gitea on startup using a one-time registration token and deregisters on graceful shutdown. This means:

- Crashed or deleted pods do not leave zombie runner registrations behind in Gitea.
- New pods are always registered with a fresh identity — no stale state from previous runs.
- The runner registration token is generated by the bootstrap script via the Gitea API and stored as a Kubernetes `Secret`; it is never committed to this repository.

The termination grace period is set to **3660 seconds** (one hour plus one minute). This gives a running CI job a full hour to complete before the pod is force-killed during a rolling update or scale-down event.

---

### KEDA for Runner Autoscaling

The runner `Deployment` holds a **warm floor of 5 replicas**. KEDA's `github-runner` trigger is designed and documented against GitHub's own Actions API; its HTTP client builds every request from the configurable `githubApiURL` rather than hardcoding `api.github.com`, which is *why* pointing it at Gitea's Actions-compatible API (`apps/gitea-runner/scaledobject.yaml`) is plausible — but KEDA's own docs never mention Gitea, so treat that compatibility as unverified, not documented. Scaling is intended to work by queued job count:

| Condition         | Replicas                                                     |
| ----------------- | ------------------------------------------------------------ |
| No jobs queued    | 5 (floor — also the fallback if the Gitea API is unreachable for 3 consecutive polls) |
| Jobs queued       | 1 runner per queued job, up to 10                            |
| Post-job cooldown | Scales back down to the floor after 120 seconds              |

**Known issue, not yet fixed**: the ScaledObject's `runnerScope: global` is not a value KEDA's `github-runner` scaler recognizes (its source only accepts `org`/`ent`/`repo`; an unrecognized scope returns a hard error on every poll). Because the fallback replica count (5) equals the floor (5), a scaler that has been erroring on every poll looks identical to a healthy idle one — this may mean the "up to 10" burst path has never actually engaged. This isn't a one-value fix, either: none of `org`/`ent`/`repo` maps cleanly onto Gitea's instance-wide runner token. KEDA's actual, current answer for Gitea/Forgejo is a **separate trigger type** — `forgejo-runner` (merged, [kedacore/keda#6495](https://github.com/kedacore/keda/pull/6495)) and a dedicated `gitea-runner` type (in progress, [kedacore/keda#8087](https://github.com/kedacore/keda/pull/8087)) — not an extension of `github-runner`'s `runnerScope` enum. See the comment in `apps/gitea-runner/scaledobject.yaml` for how to confirm this is actually failing on the live cluster and what to switch to.

A `ResourceQuota` in the `gitea-runners` namespace (`apps/gitea-runner/resourcequota.yaml`) caps the worst case so a burst toward 10 replicas cannot starve Postgres/Valkey/Traefik/Argo CD, which run on the same schedulable nodes.

---

## Network Policy & Security

All namespaces with application workloads have explicit `NetworkPolicy` resources. The default posture is **deny-all ingress and egress**, with specific allow rules for each required communication path.

### Gitea allowed traffic

| Direction | Peer                              | Ports    | Purpose                                              |
| --------- | ---------------------------------- | -------- | ---------------------------------------------------- |
| Ingress   | `traefik` namespace                | 3000, 2222 | HTTP and SSH from ingress controller                |
| Ingress   | `gitea-runners` namespace          | 3000     | Runner API calls                                      |
| Ingress   | `keda` namespace                   | 3000     | KEDA job-queue polling                                |
| Ingress   | `anubis` namespace (anubis pod)    | 3000     | Open Graph metadata fetch (`OG_PASSTHROUGH`)          |
| Egress    | `gitea` namespace (pgpool)         | 5432     | Database connections                                  |
| Egress    | `gitea` namespace (valkey)         | 6379     | Cache and session store                               |
| Egress    | External                           | 443, 587 | HTTPS outbound + SMTP submission (STARTTLS) for notifications |

### Pod security highlights

| Component            | UID   | Read-only rootfs | Seccomp        | Capabilities                                            |
| --------------------- | ----- | ----------------- | -------------- | -------------------------------------------------------- |
| Traefik                | 65532 | Yes                | RuntimeDefault | drop ALL                                                  |
| cert-manager           | 1000  | Yes                | RuntimeDefault | drop ALL                                                  |
| Gitea                  | 1000  | No (writable app dir) | RuntimeDefault | drop ALL                                              |
| Act Runner (`runner`)  | 1000  | Yes                | RuntimeDefault | drop ALL                                                  |
| dind sidecar           | root  | No                 | Unconfined     | `privileged: true` (full capability set — not scoped to just `SYS_ADMIN`) |

The dind sidecar is the only privileged workload and is unavoidable for Docker-in-Docker CI execution. It is isolated to the `gitea-runners` namespace and cannot reach the Gitea or platform namespaces except through the allowed network policy rules (`apps/gitea-runner/networkpolicy.yaml` restricts its egress to the `gitea` namespace on 3000, DNS, and HTTPS/HTTP on 443/80).

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
    main → gitea-runner daemon picks up jobs
    dind → Docker daemon on 127.0.0.1:2375
          │
  On scale-down (SIGTERM):
    gitea-runner drains current job (up to 3660s grace period)
    init → deregister from Gitea API
```

Supported job labels: `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-22.04`

---

## Deployment

> Full command reference is in [COMMANDS.md](COMMANDS.md).

### Option A — Zero-touch full bootstrap (OpenTofu/Terraform + Ansible)

Provisions the VMs on Proxmox and runs the entire bootstrap end-to-end from a deploy host, with no interactive steps:

```bash
./setup.sh     # one-time: prereq check (installs OpenTofu if needed), creates terraform/terraform.tfvars
# edit terraform/terraform.tfvars (Proxmox API token, template, network)
git push       # nodes and Argo CD pull the manifests from git
./deploy.sh    # tofu/terraform → VMs → Ansible → scripts/01..03 → Argo CD converges
```

`deploy.sh` is fully non-interactive and safe to re-run. It auto-detects the IaC binary (OpenTofu preferred, Terraform as fallback; override with `TF_BIN=`). The apply also generates `ansible/inventory.yml` from the same variables that created the VMs, so node IPs, the VIP, and the K3s version have a single source of truth (`terraform/terraform.tfvars`). The Ansible playbook does not reimplement any installation logic — it runs this repo's `scripts/01..03` on the right nodes, so the manual and automated paths cannot drift.

Requirements: a Proxmox API token, an Ubuntu cloud-image template **with qemu-guest-agent preinstalled** (Terraform waits for the agent), and the DNS records `git.open-ict.hu` and `argo.git.open-ict.hu` → `145.89.192.138`.

### Option B — Manual bootstrap (per-node scripts)

#### Prerequisites

- 6 Linux nodes reachable over SSH
- IP range `172.16.10.50–172.16.10.100` available on the LAN (control-plane VIP + node addresses)
- MetalLB pool address `145.89.192.138` routable to the node uplink (external public IP)
- DNS records: `git.open-ict.hu` and `argo.git.open-ict.hu` → `145.89.192.138`
- Internet access for pulling images and Let's Encrypt challenges

#### Bootstrap order

```bash
# 1. Initialize the first control-plane node: K3s + kube-vip + network
#    foundation (MetalLB, CoreDNS) + bootstrap secrets + Argo CD + root
#    app-of-apps. From this point Argo CD deploys the application stack
#    from git; the network layer is already up and verifiable.
bash scripts/01-bootstrap-first-master.sh

# 2. Join the remaining control-plane nodes (run on master2, master3)
bash scripts/02-join-control-plane.sh

# 3. Join worker nodes (run on worker1–3)
bash scripts/03-join-worker.sh

# Runner registration/KEDA tokens and Garage layout/credentials mint
# automatically via in-cluster bootstrap Jobs once Gitea and Garage are up —
# no further manual step on the GitOps path.
```

Watch Argo CD converge:

```bash
kubectl get applications -n argocd -w
```

Each script is idempotent. Re-running it will not duplicate resources. To tear down the application layer:

```bash
bash scripts/05-reset-apps.sh
```

### Secrets (never committed)

Generated once by `scripts/01-bootstrap-first-master.sh` (Argo CD syncs manifests but cannot invent secret material):

| Secret                             | Namespace       | Contents                                        |
| ----------------------------------- | --------------- | ----------------------------------------------- |
| `gitea-admin`                       | `gitea`         | Gitea admin username + password                 |
| `postgresql-ha-credentials`         | `gitea`         | PostgreSQL superuser, app-DB user, repmgr passwords |
| `postgresql-ha-pgpool-credentials`  | `gitea`         | pgpool admin + health-check passwords            |
| `garage-rpc`                        | `garage`        | Garage cluster RPC secret                       |
| `anubis-key`                        | `anubis`        | Anubis ED25519 signing key                      |
| `gitea-runner-registration`         | `gitea-runners` | Act Runner registration token (placeholder)     |
| `gitea-api-token`                   | `gitea-runners` | Gitea API token for KEDA scaler (placeholder)   |

Sealed the same way as `gitea-admin` by `scripts/06-seal-secrets.sh` — see [PostgreSQL HA over a Single Instance](#postgresql-ha-over-a-single-instance) for what replaced the chart's own published default passwords.

Minted automatically once Garage and Gitea are up (`scripts/04-deploy-apps.sh` steps 7 and 10, or `apps/garage/job-bootstrap.yaml` / `apps/gitea-runner/job-bootstrap-tokens.yaml` in the GitOps path — these replace the placeholders above and add):

| Secret                             | Namespace  | Contents                                              |
| ------------------------------------ | ---------- | ------------------------------------------------------ |
| `garage-gitea-storage-credentials`  | `gitea`    | S3 access key for Gitea's LFS/packages/actions storage  |
| `garage-backups-credentials`        | `gitea`    | S3 access key for the PostgreSQL/Gitea backup CronJobs  |

Valkey runs without a password inside the cluster — an explicit upstream chart default for this deployment mode, not an oversight — and is isolated entirely by `apps/gitea/networkpolicy-valkey.yaml`.

---

## Repository Structure & Contents

This repository is organized to provide a clear separation between platform infrastructure, application workloads, and operational scripts. Below is an overview of the major directories and files at the root level, along with their purposes:

### Root-Level Files

- **setup.sh**: One-time prerequisite check for the full bootstrap (OpenTofu/Terraform, Ansible, jq present, tfvars created from the example).
- **deploy.sh**: Zero-touch full bootstrap — OpenTofu/Terraform provisions the VMs, Ansible runs `scripts/01..03`, then waits for Argo CD to converge.
- **install.sh**: Entry point script for bootstrapping the first control-plane node manually. It sources the main bootstrap script and should be run on the initial master node.
- **COMMANDS.md**: Comprehensive command reference for all deployment and operational tasks.
- **README.md**: This documentation file.

### terraform/

Provisions the VMs on Proxmox (Telmate provider, cloud-init clones of an Ubuntu template) and renders `ansible/inventory.yml` from the same variables, so addressing lives in one place (`terraform.tfvars`). Plain HCL — works with both OpenTofu and Terraform. State and tfvars are gitignored.

### ansible/

- **system-utils-install.yml**: qemu-guest-agent + base utilities on all nodes, plus `unattended-upgrades` (security and normal package updates, including the kernel, applied automatically — reboots are explicitly left to Kured; see [Automatic OS Updates](#automatic-os-updates-unattended-upgrades--kured)).
- **k3s-install.yml**: Drives this repo's `scripts/01-bootstrap-first-master.sh` on the first control plane, `02-join-control-plane.sh` on the others (serially, for etcd), and `03-join-worker.sh` on the workers; then fetches a kubeconfig pointed at the VIP. It contains no installation logic of its own.
- **inventory.yml**: Generated by Terraform — do not edit by hand.

### scripts/

Contains all automation scripts for cluster lifecycle management:

- **01-bootstrap-first-master.sh**: Initializes the first control-plane node and deploys core platform components.
- **02-join-control-plane.sh**: Used to join additional control-plane nodes to the cluster.
- **03-join-worker.sh**: Used to join worker nodes.
- **04-deploy-apps.sh**: Deploys the full application stack (Traefik, cert-manager, Gitea, etc.).
- **05-reset-apps.sh**: Removes all application workloads from the cluster.
- **lib-functions.sh**: Shared Bash functions used by other scripts.

### argocd/

The GitOps control layer — the only directory Argo CD needs to be pointed at once; everything else follows from it:

- **install/**: Kustomization pinning the upstream Argo CD release manifest (plus the `argocd-cm` patch that restores the Application health check required for app-of-apps wave ordering). Applied once by `scripts/01-bootstrap-first-master.sh`; afterwards Argo CD manages its own installation from here.
- **root-app.yaml**: The root Application (app-of-apps). Points at `argocd/apps/` — the single manifest the bootstrap script applies imperatively.
- **apps/**: One Application per component, ordered by sync waves: `argocd` (0, self-management) → `keda`, `kured`, `system-upgrade-controller`, `sealed-secrets` (1) → `traefik`, `cert-manager` (2) → `cert-manager-issuers` (3) → `anubis`, `gitea-config` (4) → `garage` (5 — its bootstrap Job mints the S3 credentials Gitea's pod spec references) → `gitea` (6, Helm chart with values from this repo) → `gitea-runner` (7). The network foundation (`platform/`) is deliberately *not* an Application — it is applied at bootstrap, before Argo CD exists.

### platform/

The network foundation — everything that defines the cluster's addresses. Owned by the bootstrap scripts, **not** Argo CD: `scripts/01-bootstrap-first-master.sh` runs `kubectl apply -k platform/` before installing Argo CD, and day-2 changes are a re-run of the same command.

- **metallb/**: MetalLB upstream manifest plus the L2 IP address pool and advertisement.
- **coredns/**: CoreDNS override resolving `git.open-ict.hu` to the MetalLB VIP inside the cluster.
- **system/kube-vip.yaml**: Static-pod template for control-plane HA — copied to each master's pod-manifests directory by the bootstrap/join scripts, never applied via the API server.

### apps/

Contains application-specific Kubernetes manifests and Kustomize overlays:

- **keda/**: KEDA operator (upstream release manifest + host-alias patch pointing `git.open-ict.hu` at the MetalLB VIP).
- **kured/**: upstream kured release manifest (DaemonSet, RBAC, sentinel hostPath mount) + a local patch for the reboot window only.
- **system-upgrade-controller/**: upstream CRDs + controller for automated K3s upgrades, plus the local server/agent `Plan` resources.
- **traefik/**: `namespace.yaml` + `values.yaml` only — the Traefik workload itself is the official Helm chart (`argocd/apps/traefik.yaml`). `kustomization.yaml` exists so Argo CD's Kustomize source-type detection applies only `namespace.yaml`, not `values.yaml` (a Helm values file, not a manifest) as a raw resource.
- **cert-manager/**: Same pattern as `traefik/` — `namespace.yaml` + `values.yaml`, the cert-manager workload is the jetstack Helm chart. `issuers/` holds the Let's Encrypt `ClusterIssuer`s as a separate wave-3 Application (`argocd/apps/cert-manager-issuers.yaml`), synced after cert-manager's CRDs/webhook are ready.
- **gitea/**: Self-hosted Git service. Contains: - `values.yaml`: Helm chart values for Gitea deployment (including the Garage-backed object storage and postgresql-ha credential wiring). - `cronjob-backup-*.yaml`: PostgreSQL and Gitea-data backups to Garage. - `ingressroute-tcp.yaml`: Traefik TCP route for SSH (port 2222). - `middleware.yaml`: Rate limiting and HTTPS redirect policies. - `networkpolicy*.yaml`: Network isolation for Gitea, PostgreSQL, Valkey, and Garage.
- **gitea-runner/**: CI/CD runner deployment — runner Deployment, KEDA ScaledObject for autoscaling, ResourceQuota for burst protection, and NetworkPolicy for isolation.
- **garage/**: Self-hosted S3-compatible object storage — Gitea's LFS/packages/actions storage and the platform backup CronJobs' upload target. Independent application, own `garage` namespace.
- **anubis/**: Bot-challenge reverse proxy sitting in front of Gitea (not an example/placeholder) — namespace, certificate, deployment (pinned image, see [Component Stack](#component-stack)), service, ingress, middleware, and network policies, plus its bot policy (`policy-configmap.yaml`).

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

Middleware resources are defined in `middleware.yaml` files found in various application directories (e.g., `apps/gitea/middleware.yaml`, `apps/anubis/middleware.yaml`, `argocd/install/middleware.yaml`). These files configure Traefik middleware components such as:

- **Rate limiting**: Protects backend services from excessive requests.
- **HTTPS redirection**: Ensures all HTTP traffic is redirected to HTTPS.
- **IP allowlisting**: Restricts a route to specific source CIDRs (`argocd/install/ip-allowlist.yaml`).

Each service can have its own middleware configuration, referenced by its IngressRoute or IngressRouteTCP resource. This modular approach allows for fine-grained traffic management and security policies per application.

---

### Kustomize

Kustomize is used only where it does real work; a directory that would otherwise contain only a `kustomization.yaml` listing local files is left as plain YAML instead (Argo CD's own source-type detection then treats it as a directory source). Verified by rendering every `kustomization.yaml` with `kubectl kustomize` (kubectl v1.36.1 / Kustomize v5.8.1).

| Path | Why it's Kustomize |
| --- | --- |
| `apps/keda/`, `apps/kured/`, `apps/system-upgrade-controller/` | Upstream release manifest (remote URL resource) + a local strategic-merge patch. |
| `argocd/install/` | Upstream Argo CD release manifest + `argocd-cm`/`argocd-cmd-params-cm` patches. |
| `platform/metallb/` | Upstream release manifest + local `IPAddressPool`/`L2Advertisement`. |
| `platform/` (top level) | Composes `metallb/` + `coredns/coredns-custom.yaml` into one `kubectl apply -k` unit for the bootstrap script. |
| `apps/garage/`, `apps/gitea-runner/` | `namespace:` field injects `metadata.namespace` into resources that don't set it themselves (verified: their ServiceAccount/Role/RoleBinding/Job manifests carry no explicit namespace) — a genuine Kustomize transformation, not just an index. |
| `apps/cert-manager/`, `apps/traefik/`, `apps/gitea/` (the `gitea-config` app) | The directory also holds a Helm `values.yaml` used via `ref:` from a multi-source Argo Application. `kustomization.yaml`'s `resources:` list is what stops Argo's directory-source detection from also trying to apply `values.yaml` as a raw manifest. |
| `apps/cert-manager/issuers/` | `commonAnnotations` transformer. |

Plain YAML (no `kustomization.yaml`): `apps/anubis/` — a pure resource list with no transformation, and no Helm values file to disambiguate away from.

## Tools & Frameworks Used

- **Kubernetes**: Container orchestration and workload management.
- **Helm**: Traefik, cert-manager, Gitea (+ its `postgresql-ha`/`valkey-cluster` subcharts), and Sealed Secrets — each a multi-source or chart-based Argo CD Application, values from this repo.
- **Traefik**: Ingress controller and TCP proxy for HTTP(S) and SSH traffic. Its middleware system implements rate limiting, HTTPS redirection, and IP allowlisting (`argocd/install/ip-allowlist.yaml`).
- **cert-manager**: Automated TLS certificate management with Let's Encrypt.
- **MetalLB**: L2 load balancer for exposing services with stable IPs.
- **KEDA**: Event-driven autoscaling for CI/CD runners.
- **kube-vip**: Floating VIP for control-plane HA.
- **kured**: Automated node reboots for security updates.

### Traffic Management with Traefik Middleware

All ingress traffic is routed through Traefik, which leverages its middleware system to enforce security and operational policies. Middleware components are attached to IngressRoute and IngressRouteTCP resources to provide:

- **Rate limiting** to protect backend services from abuse
- **Automatic HTTP to HTTPS redirection** for secure access
- **IP allowlisting** to restrict a route to specific source CIDRs

This approach ensures consistent, centralized traffic management across all applications and services deployed in the cluster.

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
