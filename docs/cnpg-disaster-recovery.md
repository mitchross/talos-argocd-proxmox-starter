# CNPG Database Disaster Recovery

## Overview

CloudNativePG (CNPG) databases are backed up via **Barman** to S3-compatible storage. Unlike PVC backups (which auto-restore via Kyverno + PVC Plumber), database recovery is **manual** and must bypass ArgoCD.

## Why Recovery Can't Go Through ArgoCD

ArgoCD uses **Server-Side Apply (SSA)**. CNPG has a **mutating admission webhook** that adds `initdb` defaults to every Cluster creation. When combined:

1. ArgoCD sends SSA patch with `bootstrap.recovery`
2. CNPG webhook intercepts and adds `bootstrap.initdb` defaults
3. SSA merges both field managers — `initdb` wins
4. Result: fresh empty database, every time

Additionally, ArgoCD ApplicationSets enforce `selfHeal: true`, recreating deleted clusters in sub-second — too fast to manually intervene.

**Solution**: Apply recovery manifests directly with `kubectl create`, bypassing ArgoCD entirely.

## Backup Architecture

```
CNPG Cluster
    ↓ (continuous WAL archiving + scheduled base backups)
Barman → S3-compatible storage
    s3://<bucket>/cnpg/<app>/<serverName>/base/     (base backups)
    s3://<bucket>/cnpg/<app>/<serverName>/wals/     (WAL files)
```

### Current Database Inventory

| Database | S3 Path | Current serverName | Schedule |
|----------|---------|-------------------|----------|
| immich | `s3://postgres-backups/cnpg/immich` | `immich-database-v1` | Daily 2am + WAL |

### serverName Versioning

CNPG requires a **clean WAL archive** for new clusters. After recovery, the new cluster can't write WALs to the same path as the old cluster. The `serverName` in `backup.barmanObjectStore` controls the subdirectory:

```
s3://postgres-backups/cnpg/immich/
├── immich-database-v1/     ← current (pre-recovery backups)
│   ├── base/
│   └── wals/
└── immich-database-v2/     ← after first recovery
    ├── base/
    └── wals/
```

**Each recovery bumps the version**: `-v1` → `-v2` → `-v3`, etc.

## Recovery Procedure

### Prerequisites

- Cluster is running (ArgoCD has bootstrapped)
- CNPG operator is deployed
- `cnpg-s3-credentials` secret exists in `cloudnative-pg` namespace
- Barman backups exist on S3

### Step-by-Step (Immich)

**1. Check if backups exist:**

```bash
# CHANGE: Replace endpoint URL and bucket path with your S3 values
kubectl run -it --rm barman-check --image=amazon/aws-cli:latest \
  --restart=Never --namespace=cloudnative-pg --overrides='{
  "spec":{"containers":[{"name":"check","image":"amazon/aws-cli:latest",
  "command":["sh","-c","aws --endpoint-url http://your-s3-endpoint:9000 s3 ls s3://postgres-backups/cnpg/immich/immich-database-v1/base/ 2>&1 | tail -5"],
  "env":[
    {"name":"AWS_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"cnpg-s3-credentials","key":"AWS_ACCESS_KEY_ID"}}},
    {"name":"AWS_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"cnpg-s3-credentials","key":"AWS_SECRET_ACCESS_KEY"}}}
  ]}]}}'
```

**2. Edit the cluster.yaml:**

In `infrastructure/database/cnpg/immich/cluster.yaml`:
- Comment out the `initdb` bootstrap section
- Uncomment the `recovery` bootstrap + `externalClusters` section
- Set `externalClusters[].barmanObjectStore.serverName` to the **current** backup serverName (e.g. `immich-database-v1`)
- Bump `backup.barmanObjectStore.serverName` to the **next** version (e.g. `immich-database-v2`)

**3. Extract just the Cluster resource:**

```bash
kubectl kustomize infrastructure/database/cnpg/immich/ \
  | awk '/^apiVersion: postgresql.cnpg.io\/v1/{p=1} p{print} /^---/{if(p) exit}' \
  > /tmp/immich-recovery.yaml

# Verify it has recovery, not initdb:
grep -c "recovery" /tmp/immich-recovery.yaml  # should be >= 1
grep -c "initdb" /tmp/immich-recovery.yaml    # should be 0
```

**4. Delete and immediately recreate (one command — ArgoCD is fast):**

```bash
kubectl delete cluster immich-database -n cloudnative-pg --wait=false; \
  sleep 15; \
  kubectl create -f /tmp/immich-recovery.yaml
```

The 15-second sleep ensures old PVCs are cleaned up by Longhorn.

**5. Monitor recovery:**

```bash
# Watch cluster status
kubectl get clusters -n cloudnative-pg -w

# Watch recovery pod logs
kubectl logs -n cloudnative-pg -l cnpg.io/cluster=immich-database -f
```

Recovery typically takes 1-5 minutes depending on backup size.

**6. Verify data:**

```bash
kubectl exec -n cloudnative-pg immich-database-1 -- \
  psql -U postgres -d immich -c "SELECT count(*) FROM \"user\";"
```

**7. Revert to normal operation:**

In `cluster.yaml`:
- Uncomment `initdb` bootstrap
- Comment out `recovery` bootstrap + `externalClusters`
- Keep the new `serverName` in the backup section (e.g. `immich-database-v2`)
- Update the commented recovery `externalClusters.serverName` to match the new backup serverName

```bash
git add infrastructure/database/cnpg/immich/cluster.yaml
git commit -m "CNPG: revert immich to initdb after successful recovery"
git push
```

ArgoCD syncs. CNPG ignores `initdb` bootstrap on existing clusters — your data is safe.

## Troubleshooting

### "Expected empty archive"

**Cause**: `backup.barmanObjectStore.serverName` matches old backup path (WALs already exist).

**Fix**: Bump `serverName` to next version (e.g. `-v1` → `-v2`).

### "no target backup found"

**Cause**: `externalClusters[].barmanObjectStore.serverName` is wrong or missing.

**Fix**: Set it to the serverName that the old backups were written under. Check S3:
```bash
# CHANGE: Replace endpoint URL with your S3 endpoint
aws --endpoint-url http://your-s3-endpoint:9000 s3 ls s3://postgres-backups/cnpg/immich/
# Lists subdirectories like: immich-database-v1/, immich-database-v2/
```

### ArgoCD recreates cluster before manual apply

**Cause**: `selfHeal: true` in ApplicationSet template.

**Fix**: Use `delete --wait=false; sleep 15; kubectl create` in rapid succession. The sleep gives PVCs time to terminate.

### Recovery pod stuck in Pending

**Cause**: Old PVCs from previous cluster still terminating (Longhorn cleanup).

**Fix**: Wait 15-30 seconds for PVCs to fully delete, then recreate the cluster.

### "Only one bootstrap method can be specified"

**Cause**: Both `initdb` and `recovery` present in manifest (ArgoCD SSA merged them).

**Fix**: Don't use `kubectl apply`. Use `kubectl create` to bypass SSA.

## Verifying Backups Are Running

```bash
# Check scheduled backups
kubectl get scheduledbackup -n cloudnative-pg

# Check latest backup timestamp
kubectl get backup -n cloudnative-pg --sort-by=.metadata.creationTimestamp | tail -5

# Check WAL archiving status
kubectl get cluster -n cloudnative-pg -o jsonpath='{range .items[*]}{.metadata.name}: {.status.firstRecoverabilityPoint}{"\n"}{end}'
```

## Two Backup Systems Summary

```
┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│     PVC BACKUPS (App Data)       │    │   DATABASE BACKUPS (CNPG)        │
│                                  │    │                                  │
│  Tool: VolSync + Kopia           │    │  Tool: CNPG + Barman             │
│  Dest: NFS                       │    │  Dest: S3-compatible storage     │
│  Auto-restore: YES               │    │  Auto-restore: NO                │
│    (PVC Plumber + Kyverno)       │    │    (manual kubectl create)       │
│  Trigger: PVC label              │    │  Trigger: ScheduledBackup CRD    │
│  Schedule: hourly/daily          │    │  Schedule: daily + WAL           │
│                                  │    │                                  │
│  Covers:                         │    │  Covers:                         │
│  - App configs/data              │    │  - User accounts                 │
│  - Thumbnails/previews           │    │  - Metadata (albums, tags)       │
│  - ML model caches               │    │  - Search indexes                │
│                                  │    │  - App state                     │
└──────────────────────────────────┘    └──────────────────────────────────┘
```

## Production Notes

This starter kit uses **plain Kubernetes Secrets** with `CHANGE-ME` placeholders for S3 credentials. For production deployments, consider:

- **ExternalSecret** (with 1Password, Vault, AWS Secrets Manager) for automated credential sync
- **SealedSecret** for encrypted secrets stored in Git
- **IRSA/Pod Identity** (on AWS/Azure) to avoid static credentials entirely
