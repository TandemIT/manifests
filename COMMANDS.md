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

Don't rebuild `k3s_control_plane[0]` this way. `deploy.sh` always runs
`scripts/01` (`--cluster-init`) on that node, so a fresh VM there would start
a new cluster.

Lowering `control_plane_count` or `worker_count` deletes the highest-numbered
node without draining it, so drain it first.

## Reset the application layer

```bash
bash scripts/05-reset-apps.sh      # -f skips the confirmation
```

This deletes the app namespaces, **including the bootstrap and provider
secrets**. Afterwards, re-run `scripts/01-bootstrap-first-master.sh` on the first control
plane (it recreates missing secrets and skips existing ones) and
`scripts/06-auth-providers.sh`. Then Argo CD brings the apps back.

## Uninstall K3s

```bash
/usr/local/bin/k3s-uninstall.sh          # control-plane nodes
/usr/local/bin/k3s-agent-uninstall.sh    # workers
```
