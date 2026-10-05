# Commands

Setup is in [README.md](README.md). Changes under `apps/` and `argocd/` take
effect when pushed to `master`: Argo CD pulls from GitHub and self-heals, so
a manual `kubectl apply` there gets reverted.

## Cluster access

```bash
export KUBECONFIG="$PWD/kubeconfig"   # written by deploy.sh, server = VIP

# Manual setup: fetch it from a control plane and point it at the VIP
ssh ubuntu@<control-plane-ip> 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's|127.0.0.1|172.16.10.50|' > kubeconfig
```

## Verify the cluster

```bash
kubectl get nodes -o wide                               # all nodes Ready
kubectl get pods -n kube-system | grep kube-vip         # one per control plane
kubectl get pods -n metallb-system                      # controller + speakers
kubectl get ipaddresspool,l2advertisement -n metallb-system
kubectl get pods -A -l name=kured                       # one per node
kubectl get plans -n system-upgrade                     # K3s upgrade Plans
```

## Argo CD

```bash
kubectl get applications -n argocd -w                   # watch convergence
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d            # admin password
kubectl port-forward svc/argocd-server -n argocd 8080:443   # UI at http://localhost:8080 (or https://argo.git.open-ict.hu from a private range)
argocd app sync <name>                                  # force a sync instead of waiting for the poll
kubectl kustomize apps/gitea-runner/                    # preview what a Kustomize dir renders
```

## Platform layer (not managed by Argo CD)

```bash
kubectl apply -k platform/    # after changing the MetalLB pool or the CoreDNS override
```

kube-vip is a static pod. After editing `platform/system/kube-vip.yaml`,
re-render it as root on each control plane, from the repo checkout:

```bash
IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
sed -e "s|value: eth0|value: ${IFACE}|" \
    -e "s|value: \"172.16.10.50\"|value: \"${VIP:-172.16.10.50}\"|" \
  platform/system/kube-vip.yaml > /var/lib/rancher/k3s/agent/pod-manifests/kube-vip.yaml
```

## Secrets

```bash
# OIDC/LDAP providers: edit terraform/terraform.tfvars, then (reads tfvars directly; needs `tofu -chdir=terraform init`):
bash scripts/06-auth-providers.sh
# commit + push apps/gitea/values-oidc.yaml / values-ldap.yaml if it reports a change, then:
kubectl rollout restart deployment/gitea -n gitea
# A provider on a new host also needs that host in [security] ALLOWED_HOST_LIST
# (apps/gitea/values.yaml, EGRESS_MODE strict), or its avatar fetches are blocked.

# After removing a whole section from gitea.config in apps/gitea/values.yaml:
# chart <= 12.7.0 never prunes it from the gitea-inline-config Secret, and
# app.ini is rebuilt from that Secret on every start. Argo CD recreates it from git.
kubectl delete secret gitea-inline-config -n gitea
kubectl rollout restart deployment/gitea -n gitea

# gitea-app-secrets: never rotate secret-key, it decrypts Actions secrets, 2FA,
# webhook secrets and mirror credentials in the DB. internal-token, jwt-secret
# and lfs-jwt-secret can be replaced plus a restart (the JWT ones invalidate
# issued LFS and HS256 OAuth2 tokens).

# Rotate the Gitea /metrics bearer token
kubectl delete secret gitea-metrics-token -n gitea
kubectl create secret generic gitea-metrics-token -n gitea \
  --from-literal=token="$(openssl rand -hex 32)"
kubectl rollout restart deployment/gitea -n gitea

# Rotate the Anubis signing key (invalidates active challenge cookies)
kubectl delete secret anubis-key -n anubis
kubectl create secret generic anubis-key -n anubis \
  --from-literal=ED25519_PRIVATE_KEY_HEX="$(openssl rand -hex 32)"
kubectl rollout restart deployment/anubis -n anubis

# Re-mint the runner registration token (e.g. after revoking it in Gitea); Argo CD re-runs the Job
kubectl delete secret gitea-runner-registration -n gitea-runners
kubectl delete job runner-token-bootstrap -n gitea-runners

# Re-run the Garage bootstrap (layout + S3 keys; skips what already exists)
kubectl delete job garage-bootstrap -n garage
```

## Runners

```bash
kubectl get deployment gitea-runner -n gitea-runners
kubectl get secret gitea-runner-registration -n gitea-runners -o jsonpath='{.data.token}' | base64 -d

# Infra runner (Cloud-Infra org only, label "infra"); re-mint its token:
kubectl get deployment gitea-runner-infra -n gitea-runners-infra
kubectl delete secret gitea-runner-infra-registration -n gitea-runners-infra
kubectl delete job runner-infra-token-bootstrap -n gitea-runners-infra
```

The deploy job runs in `images/deploy/` (OpenTofu, Ansible, kubectl). To bump
a tool: edit its `ARG` there and push. `deploy-image.yml` builds and pushes the
image and prints its digest; put that digest in `deploy.yml`
(`container.image`) and push again.

## State

The OpenTofu state is in Gitea's package registry (org `Cloud-Infra`,
package `k3s-proxmox`), encrypted with `TF_VAR_state_passphrase` before it
leaves the machine. Settings for every `tofu`/`deploy.sh` run:

```bash
export TF_VAR_state_passphrase='...'
export TF_HTTP_ADDRESS=https://git.open-ict.hu/api/packages/Cloud-Infra/terraform/state/k3s-proxmox
export TF_HTTP_USERNAME=<gitea user> TF_HTTP_PASSWORD=<token with write:package>
export TF_HTTP_LOCK_ADDRESS="${TF_HTTP_ADDRESS}/lock" TF_HTTP_UNLOCK_ADDRESS="${TF_HTTP_ADDRESS}/lock"
```

```bash
# Off-cluster copy (encrypted as stored) into state-backups/, after every apply
bash scripts/07-pull-state.sh

# Stuck lock (a deploy killed mid-apply): check nothing is running first
tofu -chdir=terraform force-unlock <lock id from the error>
```

One-time move from the old local `terraform/terraform.tfstate` (unencrypted)
to Gitea: the `unencrypted "migrate"` fallback in `terraform/main.tf` reads it.

```bash
tofu -chdir=terraform init -migrate-state      # answer yes
tofu -chdir=terraform state list               # same resources as before
bash scripts/07-pull-state.sh                  # confirms the stored state is encrypted
# then delete terraform/terraform.tfstate*, and remove the "migrate" method
# and its fallback from terraform/main.tf in a follow-up commit
```

Rebuild with no Gitea (first bootstrap, cluster lost): use a local copy.

```bash
cat > terraform/backend_override.tf <<'EOF'
terraform {
  backend "local" {}
}
EOF
cp state-backups/<latest>.tfstate terraform/terraform.tfstate   # skip on a first bootstrap
tofu -chdir=terraform init -reconfigure
./deploy.sh
# Restore gitea-app-secrets (Backups) before restoring the database. Once
# Gitea is back and Cloud-Infra exists, move the state back:
rm terraform/backend_override.tf
tofu -chdir=terraform init -migrate-state
```

### Deploy workflow (`.gitea/workflows/deploy.yml`)

Runs `deploy.sh` on the infra runner for every push to master of the
`Cloud-Infra` repo, a pull mirror of this GitHub repo (a mirror sync counts as
a push). Once, in that repo's Settings:

- Actions enabled; mirror interval as short as you want deploys to lag GitHub.
- Secrets `VM_PASSWORD`, `STATE_PASSPHRASE`, `STATE_TOKEN`, `SSH_PRIVATE_KEY`,
  and the credentials from `terraform.tfvars`: `PROXMOX_API_TOKEN_ID`,
  `PROXMOX_API_TOKEN_SECRET`, `GITEA_OIDC_PROVIDERS`, `GITEA_LDAP_PROVIDERS`
  (the value after `=`, e.g. `{ authentik = { ... } }`; strings without
  quotes). Variable `STATE_USER`. Settings come from `cluster.auto.tfvars`.
- `STATE_TOKEN` belongs to a bot account (or user) in a `Cloud-Infra` team
  with package write, scope `write:package`. The job's own token can only read
  packages in Gitea 28.

```bash
# Force a run without waiting for the mirror interval: sync the mirror
curl -X POST -u "<user>:<token>" https://git.open-ict.hu/api/v1/repos/Cloud-Infra/<repo>/mirror-sync
```

## Backups

```bash
# Run a backup now (also: backup-gitea-data, backup-garage-storage)
kubectl create job --from=cronjob/backup-postgresql backup-postgresql-manual -n gitea
```

Restore from a pod in the `gitea` namespace (Garage only admits that
namespace), with `garage-backups-credentials` as `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` and `AWS_REGION=garage`. Always restore into a scratch
target first:

```bash
aws --endpoint-url http://garage.garage.svc.cluster.local:3900 s3 ls s3://platform-backups/postgresql/

aws --endpoint-url http://garage.garage.svc.cluster.local:3900 s3 cp \
  s3://platform-backups/postgresql/gitea-<timestamp>.sql.gz - | gunzip | \
  psql -h gitea-postgresql-ha-pgpool -U postgres -d gitea_restore_test

aws --endpoint-url http://garage.garage.svc.cluster.local:3900 s3 cp \
  s3://platform-backups/gitea-data/gitea-data-<timestamp>.tar.gz - | tar -tzv | head
```

The dumps are useless without `gitea-app-secrets` (its `secret-key` decrypts
Actions secrets, 2FA, webhook secrets and mirror credentials). No backup job
captures it: keep a copy off-cluster, next to `terraform.tfvars`.

```bash
# Export (plaintext: store it like terraform.tfvars)
kubectl get secret gitea-app-secrets -n gitea -o go-template=\
'{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}' > gitea-app-secrets.env

# After a rebuild: put it back before restoring the PostgreSQL dump
kubectl delete secret gitea-app-secrets -n gitea
kubectl create secret generic gitea-app-secrets -n gitea --from-env-file=gitea-app-secrets.env
kubectl rollout restart deployment/gitea -n gitea
```

## Public NIC (public0)

```bash
# Re-apply only the public0 config (netplan, nftables guard, rp_filter, reply routing)
ansible-playbook -i ansible/inventory.yml ansible/system-utils-install.yml --tags public-nic

# On a node: the reply rule/route and the guard table
ip rule | grep 'lookup 105'
ip route show table 105
sudo nft list table inet public0
```

## Node maintenance

Always one node at a time. Changing `count` instances that need a replace or
reboot affects every node at once.

```bash
# Reboot (e.g. for a pending Proxmox change; apply never reboots, automatic_reboot = false)
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh ubuntu@<node-ip> sudo reboot
kubectl uncordon <node>

# Rebuild one VM (template, clone mode, VM ID and EFI disk changes are ignored on existing VMs)
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>
tofu -chdir=terraform apply -replace='proxmox_vm_qemu.k3s_worker[0]'   # or k3s_control_plane[i]
./deploy.sh                                                            # rejoins the new VM; joined nodes are skipped
```

For `k3s_control_plane[0]`, `deploy.sh` checks whether another control plane
answers on 6443. If one does, it deletes the stale node there (if you haven't
already) and joins the fresh VM with `scripts/02`, using that peer's token. If
none answers but a peer already has K3s, it stops rather than run `scripts/01`
(`--cluster-init`). `-e k3s_force_bootstrap=true` on the `ansible-playbook`
call overrides that.

Changes to `public_vlan_tag` (and the NIC itself, on VMs created before it
existed) reach only new VMs, so rebuild each existing node this way to get them.

Lowering `control_plane_count` or `worker_count` deletes the highest-numbered
node without draining it, so drain it first.

## Reset the application layer

```bash
bash scripts/05-reset-apps.sh      # -f skips the confirmation
```

This deletes the app namespaces and their data (PVCs). The bootstrap and
OIDC/LDAP secrets are saved first and restored at the end, so Argo CD brings
the apps back on its own. The runner token and Garage S3 keys are minted
again by the bootstrap Jobs.

Gitea's database goes too: the OpenTofu state, the `Cloud-Infra` mirror repo
and its Actions secrets. The script refuses to run without a
`state-backups/` copy (`scripts/07-pull-state.sh`). Afterwards, move the state
back (State) and set the repo up again (Deploy workflow).

## Uninstall K3s

```bash
/usr/local/bin/k3s-uninstall.sh          # control-plane nodes
/usr/local/bin/k3s-agent-uninstall.sh    # workers
```
