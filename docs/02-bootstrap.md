# Bootstrap Guide

## Step 1: Clone and Configure

```bash
git clone https://github.com/mitchross/talos-argocd-proxmox-starter.git
cd talos-argocd-proxmox-starter
```

Search for `CHANGE` comments and update values:
```bash
grep -rn "CHANGE" --include="*.yaml" .
```

Key values to update:
- **NFS server IP** and **path** (2 files)
- **Git repo URL** (all files in `infrastructure/controllers/argocd/apps/`)
- **Domain name** (gateway files)
- **Cilium IP pool** and **gateway IPs**
- **Secret values** (all files in `secrets/`)

## Step 2: Install Cilium

```bash
cilium install \
    --version 1.19.0 \
    --set cluster.name=demo-cluster \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set hubble.enabled=false \
    --set hubble.relay.enabled=false \
    --set hubble.ui.enabled=false \
    --set gatewayAPI.enabled=true

# Wait for Cilium to be ready
cilium status --wait
```

## Step 3: Apply Secrets

Edit the secret files with real values, then apply:

```bash
# Create namespaces first
kubectl create namespace volsync-system
kubectl create namespace cloudnative-pg
kubectl create namespace immich
kubectl create namespace karakeep

# Apply all secrets
kubectl apply -f secrets/kopia-credentials.yaml
kubectl apply -f secrets/immich-db-init-secret.yaml
kubectl apply -f secrets/immich-db-credentials.yaml
kubectl apply -f secrets/karakeep-secret.yaml
```

## Step 4: Commit and Push

If you forked the repo, commit your changes:
```bash
git add -A
git commit -m "Configure for my cluster"
git push
```

## Step 5: Bootstrap ArgoCD

```bash
./scripts/bootstrap-argocd.sh
```

## Step 6: Watch the Magic

```bash
# Watch applications sync in wave order
kubectl get applications -n argocd -w

# Detailed sync wave view
kubectl get applications -n argocd \
  -o custom-columns=NAME:.metadata.name,WAVE:.metadata.annotations.argocd\\.argoproj\\.io/sync-wave,STATUS:.status.sync.status,HEALTH:.status.health.status
```

Expected order:
1. `cilium` (Wave 0) - Already running, syncs config
2. `longhorn` (Wave 1) - Storage layer deploys
3. `snapshot-controller` (Wave 1) - VolumeSnapshot CRDs
4. `volsync` (Wave 1) - Backup operator
5. `pvc-plumber` (Wave 2) - Backup checker starts
6. `kyverno` (Wave 3) - Policy engine + webhooks register
7. Infrastructure apps (Wave 4) - Gateway, NFS CSI, CNPG
8. `my-apps-immich`, `my-apps-karakeep` (Wave 6) - Apps deploy, PVCs trigger Kyverno

## Step 7: Verify Backup System

```bash
# Check Kyverno generated resources for Karakeep (has backup: hourly label)
kubectl get replicationsource,replicationdestination,secret -n karakeep -l app.kubernetes.io/managed-by=kyverno

# Check PVC Plumber is healthy
kubectl get pods -n volsync-system -l app.kubernetes.io/name=pvc-plumber

# Check VolSync operator
kubectl get pods -n volsync-system
```

## Troubleshooting

### Apps stuck in "Missing"
ArgoCD hasn't synced yet. Check the controller logs:
```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=50
```

### PVCs stuck in Pending
Longhorn might not be ready. Check:
```bash
kubectl get pods -n longhorn-system
kubectl get sc
```

### Kyverno policies not generating resources
Check Kyverno background controller:
```bash
kubectl logs -n kyverno -l app.kubernetes.io/component=background-controller --tail=50
```

### PVC creation denied
PVC Plumber is down (fail-closed). Check:
```bash
kubectl get pods -n volsync-system -l app.kubernetes.io/name=pvc-plumber
kubectl logs -n volsync-system -l app.kubernetes.io/name=pvc-plumber
```
