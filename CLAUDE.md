# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

YouTube demo starter kit for **intent-based data protection** on Kubernetes. The key innovation: add `backup: "hourly"` to a PVC label, and Kyverno automatically generates the entire backup/restore infrastructure. Includes CNPG database backup via Barman to S3.

**Tech Stack**: ArgoCD + Cilium (Gateway API) + Longhorn + Kyverno + VolSync + CNPG

## Core Architecture: GitOps Self-Management

```
Manual Bootstrap → ArgoCD → Root App → ApplicationSets → Auto-discovered Apps
```

1. **Bootstrap once**: `./scripts/bootstrap-argocd.sh` installs ArgoCD via Helm
2. **Root app triggers**: Points ArgoCD to scan `infrastructure/controllers/argocd/apps/`
3. **ApplicationSets discover**: Scan directories and auto-create Applications
4. **Everything else is automatic**: Add directory + `kustomization.yaml` = deployed app

**Directory = Application**:
```
my-apps/media/immich/     → ArgoCD Application "immich"
my-apps/media/karakeep/   → ArgoCD Application "karakeep"
```

## Sync Wave Architecture

Applications deploy in strict order to prevent race conditions:

| Wave | Component | Purpose |
|------|-----------|---------|
| **0** | Cilium | CNI + Gateway API + L2 announcements |
| **1** | Longhorn, VolSync, Snapshot Controller | Storage layer |
| **2** | PVC Plumber | Backup existence checker (FAIL-CLOSED gate) |
| **3** | Kyverno | Policy engine (standalone App, not in AppSet) |
| **4** | Infrastructure AppSet | Gateway, NFS CSI, CNPG databases |
| **6** | My-Apps AppSet | Immich, Karakeep (PVCs trigger Kyverno) |

**Critical**: Kyverno is a **standalone Application** (not in an AppSet) to guarantee webhooks register before app PVCs are created.

## Two Backup Systems

### PVC Backups (Automatic)

- **Tool**: VolSync + Kopia → NFS
- **Trigger**: Add `backup: "hourly"` or `backup: "daily"` label to PVC
- **Auto-restore**: YES — PVC Plumber checks for backups on PVC creation, Kyverno adds dataSourceRef
- **Fail-closed**: PVC creation denied if PVC Plumber is down (prevents empty volumes during DR)
- **Why NFS over S3**: No per-namespace credentials (Kyverno injects one NFS mount), cross-PVC dedup (all PVCs share one Kopia repo), direct filesystem speed. S3+Restic = per-PVC repos with zero dedup.

### Database Backups (Manual Recovery)

- **Tool**: CNPG + Barman → S3-compatible storage
- **Trigger**: ScheduledBackup CRD (daily at 2am + continuous WAL)
- **Auto-restore**: NO — requires manual `kubectl create` bypassing ArgoCD
- **Why manual**: ArgoCD SSA + CNPG webhook conflict makes `initdb` always win over `recovery`

### CNPG Disaster Recovery Quick Reference

| Database | Current serverName | S3 Path |
|----------|-------------------|---------|
| immich | `immich-database-v1` | `s3://postgres-backups/cnpg/immich` |

**Recovery steps** (must bypass ArgoCD):
1. Comment out `initdb`, uncomment `recovery` + `externalClusters` in cluster.yaml
2. Set `externalClusters.serverName` to current backup serverName
3. Bump `backup.serverName` to next version (e.g. `-v1` → `-v2`)
4. `kubectl kustomize ... > /tmp/recovery.yaml`
5. `kubectl delete cluster ... --wait=false; sleep 15; kubectl create -f /tmp/recovery.yaml`
6. Verify, then revert to `initdb` and push

See [docs/cnpg-disaster-recovery.md](docs/cnpg-disaster-recovery.md) for full procedure.

## Kyverno Policies

Located in `infrastructure/controllers/kyverno/policies/`:

1. **volsync-pvc-backup-restore.yaml** — Main backup/restore automation (5 rules)
   - Rule 0: Validate PVC Plumber is healthy (FAIL-CLOSED)
   - Rule 1: Add dataSourceRef if backup exists (auto-restore)
   - Rules 2-4: Generate Secret, ReplicationSource, ReplicationDestination
2. **volsync-nfs-inject.yaml** — Injects NFS mount into VolSync mover jobs
3. **volsync-orphan-cleanup.yaml** — Deletes orphaned resources when backup label removed (every 15min)

## Directory Structure

```
infrastructure/
├── controllers/
│   ├── argocd/          # ArgoCD + root app + sync wave Applications
│   ├── kyverno/         # Policy engine + 3 backup policies
│   └── pvc-plumber/     # Backup existence checker
├── database/
│   └── cnpg/            # CNPG operator + Immich Postgres cluster
├── networking/
│   ├── cilium/          # CNI + L2 announcements
│   └── gateway/         # Gateway API (external + internal)
└── storage/
    ├── longhorn/        # Block storage + VolumeSnapshotClass
    ├── volsync/         # Backup operator
    ├── snapshot-controller/
    └── csi-driver-nfs/

my-apps/
└── media/
    ├── immich/          # Photo management (server + ML + Valkey + CNPG)
    └── karakeep/        # Bookmark manager (web + Meilisearch + Chrome)

secrets/                 # Template secrets (CHANGE-ME placeholders)
docs/                    # Setup guides, demos, DR procedures
scripts/                 # Bootstrap automation
```

## Secrets Management

This starter kit uses **plain Kubernetes Secrets** with `CHANGE-ME` placeholders:

| Secret | Namespace | Purpose |
|--------|-----------|---------|
| `kopia-credentials` | `volsync-system` | PVC Plumber + Kyverno (backup encryption) |
| `immich-app-secret` | `cloudnative-pg` | CNPG cluster bootstrap (DB owner) |
| `immich-db-credentials` | `immich` | Immich server (DB connection) |
| `cnpg-s3-credentials` | `cloudnative-pg` | CNPG Barman backup (S3 access) |
| `karakeep-secret` | `karakeep` | Karakeep web app (NextAuth, Meili) |

For production, swap plain Secrets for ExternalSecret (1Password/Vault) or SealedSecret.

## Key Patterns

### Adding a New App

```bash
mkdir -p my-apps/category/app-name
# Create: namespace.yaml, kustomization.yaml, deployment.yaml, service.yaml
# ArgoCD auto-discovers via ApplicationSet
```

### Adding PVC Backup

```yaml
metadata:
  labels:
    backup: "hourly"  # Kyverno auto-generates all backup resources
```

### CHANGE Markers

All values requiring user customization are marked with `# CHANGE:` or use `CHANGE-ME` placeholders:
```bash
grep -rn "CHANGE" --include="*.yaml" .
```

## Critical Rules

**DO:**
- Use `storageClassName: longhorn` for PVCs that need backups
- Keep PVC names consistent for restore to work
- Bump CNPG `serverName` after each database recovery
- Apply secrets before running `bootstrap-argocd.sh`
- Use Gateway API (HTTPRoute), not Ingress

**DON'T:**
- Add backup labels to CNPG-managed PVCs (use Barman instead)
- Use `kubectl apply` for CNPG recovery (use `kubectl create` to bypass SSA)
- Create manual ArgoCD Application resources (use directory discovery)
- Delete Kyverno-managed resources (they'll be recreated)
- Commit real secret values to Git

## Documentation

| Doc | Description |
|-----|-------------|
| [Prerequisites](docs/00-prerequisites.md) | What you need before starting |
| [NFS Setup](docs/01-nfs-setup.md) | NFS server configuration |
| [Bootstrap Guide](docs/02-bootstrap.md) | Step-by-step deployment |
| [Backup Demo](docs/03-backup-demo.md) | PVC backup pipeline walkthrough |
| [Restore Demo](docs/04-restore-demo.md) | Disaster recovery with auto-restore |
| [Architecture](docs/architecture.md) | System design and data flow |
| [CNPG Disaster Recovery](docs/cnpg-disaster-recovery.md) | Database backup and recovery |
