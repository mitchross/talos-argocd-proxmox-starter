# CNPG Disaster Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add CNPG database backup (Barman → S3) and disaster recovery to the starter kit, with templated S3 config and full documentation.

**Architecture:** CNPG's built-in Barman integration continuously archives WAL files and takes scheduled base backups to S3-compatible storage. Recovery bypasses ArgoCD (SSA + CNPG webhook conflict) via direct `kubectl create`. serverName versioning (-v1, -v2, ...) ensures clean WAL archives after each recovery.

**Tech Stack:** CloudNativePG, Barman, S3-compatible storage, Kustomize

**Design doc:** `docs/plans/2026-02-15-cnpg-disaster-recovery-design.md`

---

### Task 1: Update CNPG cluster.yaml with backup config and DR comments

**Files:**
- Modify: `infrastructure/database/cnpg/immich/cluster.yaml`

**Step 1: Add backup section and DR comments to cluster.yaml**

Replace the entire file with the updated version. The changes are:
- Add `backup.barmanObjectStore` with templated S3 endpoint/bucket/credentials
- Add `serverName: immich-database-v1`
- Add WAL and data compression (gzip)
- Add `retentionPolicy: "14d"`
- Add commented-out disaster recovery bootstrap section with step-by-step instructions

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: immich-database
  namespace: cloudnative-pg
  labels:
    app: immich
spec:
  instances: 1
  # VectorChord image for Immich vector search support
  imageName: ghcr.io/tensorchord/cloudnative-vectorchord:17.5-0.4.3
  resources:
    requests:
      memory: 1Gi
      cpu: 500m
    limits:
      memory: 2Gi
  postgresql:
    shared_preload_libraries:
      - "vchord.so"
    parameters:
      shared_buffers: "256MB"
      max_wal_size: "1GB"
      max_connections: "500"
      wal_compression: "on"
    pg_hba:
      - host all all 0.0.0.0/0 md5
  # === NORMAL OPERATION ===
  bootstrap:
    initdb:
      database: immich
      owner: immich
      secret:
        # CHANGE: Create this secret before deploying (see secrets/immich-db-init-secret.yaml)
        name: immich-app-secret
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
        - CREATE EXTENSION IF NOT EXISTS vector;
        - CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE;
        - GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "immich";
        - GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "immich";
        - ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "immich";
        - ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "immich";
  # === DISASTER RECOVERY ===
  # To recover from a Barman S3 backup, follow these steps:
  #
  # 1. Comment out the initdb bootstrap above
  # 2. Uncomment the recovery bootstrap + externalClusters below
  # 3. Set externalClusters[].barmanObjectStore.serverName to the CURRENT backup serverName (immich-database-v1)
  # 4. Bump backup.barmanObjectStore.serverName to the NEXT version (e.g. immich-database-v2)
  # 5. Extract the Cluster resource and apply directly (bypasses ArgoCD SSA + CNPG webhook conflict):
  #      kubectl kustomize infrastructure/database/cnpg/immich/ \
  #        | awk '/^apiVersion: postgresql.cnpg.io\/v1/{p=1} p{print} /^---/{if(p) exit}' \
  #        > /tmp/immich-recovery.yaml
  #      kubectl delete cluster immich-database -n cloudnative-pg --wait=false; \
  #        sleep 15; \
  #        kubectl create -f /tmp/immich-recovery.yaml
  # 6. After recovery, revert to initdb bootstrap and push (keep new serverName in backup section)
  #
  # See docs/cnpg-disaster-recovery.md for full procedure and troubleshooting.
  #
  # bootstrap:
  #   recovery:
  #     source: immich-backup
  # externalClusters:
  #   - name: immich-backup
  #     barmanObjectStore:
  #       serverName: immich-database-v1
  #       destinationPath: "s3://postgres-backups/cnpg/immich"    # CHANGE: your S3 bucket path
  #       endpointURL: "http://your-s3-endpoint:9000"             # CHANGE: your S3 endpoint
  #       s3Credentials:
  #         accessKeyId:
  #           name: cnpg-s3-credentials
  #           key: AWS_ACCESS_KEY_ID
  #         secretAccessKey:
  #           name: cnpg-s3-credentials
  #           key: AWS_SECRET_ACCESS_KEY
  #       wal:
  #         compression: gzip
  storage:
    size: 20Gi
    storageClass: longhorn
  walStorage:
    size: 2Gi
    storageClass: longhorn
  enableSuperuserAccess: true
  monitoring:
    enablePodMonitor: false
  backup:
    barmanObjectStore:
      serverName: immich-database-v1
      destinationPath: "s3://postgres-backups/cnpg/immich"    # CHANGE: your S3 bucket path
      endpointURL: "http://your-s3-endpoint:9000"             # CHANGE: your S3 endpoint
      s3Credentials:
        accessKeyId:
          name: cnpg-s3-credentials
          key: AWS_ACCESS_KEY_ID
        secretAccessKey:
          name: cnpg-s3-credentials
          key: AWS_SECRET_ACCESS_KEY
      wal:
        compression: gzip
      data:
        compression: gzip
    retentionPolicy: "14d"
```

**Step 2: Verify YAML is valid**

Run: `kubectl kustomize infrastructure/database/cnpg/immich/` (only works if kubectl is available, otherwise visual check is sufficient)

Expected: Valid YAML output with the Cluster resource

**Step 3: Commit**

```bash
git add infrastructure/database/cnpg/immich/cluster.yaml
git commit -m "Add Barman S3 backup config and DR comments to CNPG cluster"
```

---

### Task 2: Create ScheduledBackup resource

**Files:**
- Create: `infrastructure/database/cnpg/immich/scheduled-backup.yaml`
- Modify: `infrastructure/database/cnpg/immich/kustomization.yaml`

**Step 1: Create scheduled-backup.yaml**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: immich-daily-backup
  namespace: cloudnative-pg
spec:
  schedule: "0 2 * * *"
  backupOwnerReference: self
  cluster:
    name: immich-database
  immediate: true
```

**Step 2: Add scheduled-backup.yaml to kustomization.yaml**

Update `infrastructure/database/cnpg/immich/kustomization.yaml` to:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cloudnative-pg
commonLabels:
  app.kubernetes.io/name: immich-db
  app.kubernetes.io/managed-by: argocd
commonAnnotations:
  argocd.argoproj.io/sync-wave: "-5"
resources:
  - cluster.yaml
  - scheduled-backup.yaml
```

**Step 3: Commit**

```bash
git add infrastructure/database/cnpg/immich/scheduled-backup.yaml infrastructure/database/cnpg/immich/kustomization.yaml
git commit -m "Add ScheduledBackup for daily CNPG base backups"
```

---

### Task 3: Create S3 credentials secret template

**Files:**
- Create: `secrets/cnpg-s3-credentials.yaml`
- Modify: `secrets/README.md`

**Step 1: Create the secret template**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cnpg-s3-credentials
  namespace: cloudnative-pg
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "CHANGE-ME"
  AWS_SECRET_ACCESS_KEY: "CHANGE-ME"
```

Note: Use `CHANGE-ME` (with hyphen) to match existing secret templates in this repo.

**Step 2: Update secrets/README.md**

Add the new secret to the instructions and table. The updated file should:

- Add `kubectl apply -f secrets/cnpg-s3-credentials.yaml` to the apply commands
- Add a row to the Secret Details table:
  `cnpg-s3-credentials` | `cloudnative-pg` | CNPG Barman backup (S3 access for database backups)
- Add a note about production users swapping for ExternalSecret/SealedSecret

**Step 3: Commit**

```bash
git add secrets/cnpg-s3-credentials.yaml secrets/README.md
git commit -m "Add S3 credentials template for CNPG database backups"
```

---

### Task 4: Update bootstrap script to check for S3 credentials

**Files:**
- Modify: `scripts/bootstrap-argocd.sh`

**Step 1: Add cnpg-s3-credentials check**

Add a check for `cnpg-s3-credentials` in the `cloudnative-pg` namespace, alongside the existing secret checks (after the `immich-app-secret` check, around line 68):

```bash
if ! kubectl get secret cnpg-s3-credentials -n cloudnative-pg &> /dev/null; then
  echo "MISSING: cnpg-s3-credentials in cloudnative-pg"
  echo "  Apply: kubectl apply -f secrets/cnpg-s3-credentials.yaml"
  MISSING_SECRETS=1
fi
```

**Step 2: Commit**

```bash
git add scripts/bootstrap-argocd.sh
git commit -m "Add cnpg-s3-credentials to bootstrap secret checks"
```

---

### Task 5: Create CNPG disaster recovery documentation

**Files:**
- Create: `docs/cnpg-disaster-recovery.md`

**Step 1: Write the DR doc**

Adapted from the production repo's `docs/cnpg-disaster-recovery.md`, but genericized for the starter kit:

- Replace RustFS-specific references with generic "S3-compatible storage"
- Replace specific endpoints with `CHANGE` placeholders matching cluster.yaml
- Only include immich database (not khoj/paperless which don't exist in starter)
- Start serverName at `-v1` (not `-v2`)
- Note about using plain Secrets vs ExternalSecrets
- Keep: the ArgoCD SSA explanation, step-by-step recovery, troubleshooting, two-backup-systems diagram

The doc should cover these sections:
1. **Overview** — CNPG databases backed up via Barman to S3, recovery is manual
2. **Why Recovery Can't Go Through ArgoCD** — SSA + CNPG webhook explanation
3. **Backup Architecture** — diagram showing CNPG → Barman → S3 path
4. **Current Database Inventory** — table with immich serverName `-v1`
5. **serverName Versioning** — explanation with directory structure diagram
6. **Recovery Procedure** — step-by-step with exact commands
7. **Troubleshooting** — common errors and fixes
8. **Verifying Backups Are Running** — kubectl commands
9. **Two Backup Systems Summary** — side-by-side comparison diagram (PVC vs DB)
10. **Production Notes** — swap plain Secrets for ExternalSecret/SealedSecret

**Step 2: Commit**

```bash
git add docs/cnpg-disaster-recovery.md
git commit -m "Add CNPG disaster recovery documentation"
```

---

### Task 6: Update existing docs (backup demo, architecture, readme)

**Files:**
- Modify: `docs/03-backup-demo.md`
- Modify: `docs/architecture.md`
- Modify: `readme.md`

**Step 1: Add "Database Backups" section to docs/03-backup-demo.md**

Append a new section at the end of the file:

```markdown
## Database Backups (CNPG — Separate System)

The backup demo above covers **PVC data** (application files, caches, configs). Database backups use a **completely separate system**:

| | PVC Backups | Database Backups |
|---|---|---|
| **Tool** | VolSync + Kopia | CNPG + Barman |
| **Destination** | NFS | S3-compatible storage |
| **Trigger** | PVC label (`backup: "hourly"`) | ScheduledBackup CRD |
| **Auto-restore** | Yes (PVC Plumber + Kyverno) | **No** — manual recovery required |
| **Schedule** | Hourly or daily (per label) | Daily at 2am + continuous WAL archiving |

### Why databases don't use the PVC backup system

- Filesystem-level backup of a running Postgres database can be inconsistent
- Barman uses `pg_basebackup` + WAL archiving for point-in-time recovery
- CNPG manages its own PVCs (names are auto-generated, can't add Kyverno labels)

### Checking database backup status

```bash
# Check scheduled backups
kubectl get scheduledbackup -n cloudnative-pg

# Check latest backup
kubectl get backup -n cloudnative-pg --sort-by=.metadata.creationTimestamp

# Check WAL archiving status
kubectl get cluster -n cloudnative-pg -o jsonpath='{range .items[*]}{.metadata.name}: {.status.firstRecoverabilityPoint}{"\n"}{end}'
```

For disaster recovery procedures, see [CNPG Disaster Recovery](cnpg-disaster-recovery.md).
```

**Step 2: Add database backup section to docs/architecture.md**

After the "Components" table at the end of the file, add:

```markdown
## Database Backups (Separate Path)

CNPG databases use Barman to S3 — a separate backup path from the PVC/VolSync system:

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
└──────────────────────────────────┘    └──────────────────────────────────┘
```

See [CNPG Disaster Recovery](cnpg-disaster-recovery.md) for recovery procedures.
```

**Step 3: Update readme.md**

Add to the Documentation table (after the Architecture row):

```markdown
| [CNPG Disaster Recovery](docs/cnpg-disaster-recovery.md) | Database backup and recovery procedures |
```

Add `CNPG + Barman` to the Stack table with purpose "Database backup to S3":

```markdown
| **CNPG + Barman** | (built-in) | Database backup to S3 |
```

**Step 4: Commit**

```bash
git add docs/03-backup-demo.md docs/architecture.md readme.md
git commit -m "Update docs with database backup system and DR references"
```

---

### Task 7: Create CLAUDE.md for the starter kit

**Files:**
- Create: `CLAUDE.md`

**Step 1: Write CLAUDE.md**

Create a starter-kit-scoped version adapted from the production repo's CLAUDE.md. Include:

1. **Project Overview** — YouTube demo starter kit for intent-based data protection
2. **Core Architecture** — GitOps self-management with ArgoCD
3. **Sync Wave Architecture** — table with waves 0-6
4. **Two Backup Systems** — PVC backups (Kyverno + VolSync → NFS) and DB backups (CNPG + Barman → S3)
5. **CNPG Disaster Recovery** — quick reference with serverName table (immich: `-v1`), link to full doc
6. **Directory Structure** — current starter kit layout
7. **Key Patterns** — backup label, fail-closed gate, NFS injection
8. **Adding New Applications** — minimal app pattern
9. **Critical Rules** — DOs and DON'Ts

Keep it focused on what's in the starter kit (no GPU, monitoring, 1Password, khoj, paperless references).

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Add CLAUDE.md with project conventions and backup architecture"
```

---

### Task 8: Final review and verification

**Step 1: Verify all CHANGE/CHANGE-ME markers are consistent**

Run: `grep -rn "CHANGE" --include="*.yaml" .` — ensure all placeholder patterns use the same convention.

**Step 2: Verify all internal doc links work**

Check that links between docs reference correct filenames:
- `docs/cnpg-disaster-recovery.md` links
- `readme.md` documentation table links
- `docs/03-backup-demo.md` link to DR doc
- `docs/architecture.md` link to DR doc
- `CLAUDE.md` link to DR doc

**Step 3: Verify kustomize renders correctly**

Run: `kubectl kustomize infrastructure/database/cnpg/immich/` (if kubectl available)

**Step 4: Final commit (if any fixes needed)**

```bash
git add -A
git commit -m "Fix any issues found during review"
```
