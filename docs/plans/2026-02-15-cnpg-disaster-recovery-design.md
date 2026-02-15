# Design: CNPG Database Backup & Disaster Recovery

**Date:** 2026-02-15
**Status:** Approved
**Branch:** volsync-kyverno-demo

## Problem

The starter kit has CNPG for Immich's PostgreSQL database but no backup or disaster recovery story for it. PVC backups (VolSync/Kopia → NFS) are fully automated, but database backups are a separate concern — you can't just snapshot a running database's PVC and expect consistency.

## Approach

Port the Barman → S3 backup pattern from the production repo (`k3s-argocd-proxmox`), genericized with placeholder values so users can plug in their own S3-compatible storage (MinIO, TrueNAS, AWS S3, etc.).

Key design decisions:
- **Start serverName at `-v1`** (not bare name) so the versioning pattern is clear from day one
- **Plain Secret with CHANGE_ME placeholders** for S3 credentials (docs note to swap for ExternalSecret/SealedSecret in production)
- **Two separate backup systems** clearly documented: PVC backups (auto-restore) vs DB backups (manual recovery)

## Changes

### 1. Cluster.yaml Updates (`infrastructure/database/cnpg/immich/cluster.yaml`)

Add to the existing CNPG Cluster spec:

- `backup.barmanObjectStore` with templated S3 config (endpoint, bucket, credentials)
- `serverName: immich-database-v1` for WAL archive versioning
- `backup.retentionPolicy: "14d"`
- WAL and data compression (gzip)
- Commented-out disaster recovery bootstrap section with step-by-step instructions:
  - recovery bootstrap + externalClusters
  - Instructions for serverName bumping (-v1 → -v2 → -v3)
  - Note about bypassing ArgoCD (SSA + CNPG webhook conflict)

### 2. New File: ScheduledBackup (`infrastructure/database/cnpg/immich/scheduled-backup.yaml`)

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

### 3. New File: S3 Credentials Template (`secrets/cnpg-s3-credentials.yaml`)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cnpg-s3-credentials
  namespace: cloudnative-pg
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "CHANGE_ME"
  AWS_SECRET_ACCESS_KEY: "CHANGE_ME"
```

Docs will note: production users should swap for ExternalSecret or SealedSecret.

### 4. Kustomization Update (`infrastructure/database/cnpg/immich/kustomization.yaml`)

Add `scheduled-backup.yaml` to resources list.

### 5. New Doc: CNPG Disaster Recovery (`docs/cnpg-disaster-recovery.md`)

Adapted from production DR doc, covering:
- Why recovery can't go through ArgoCD (SSA + CNPG webhook conflict)
- Backup architecture (CNPG → Barman → S3)
- serverName versioning (start at -v1, bump on each recovery)
- Step-by-step recovery procedure
- Troubleshooting common errors
- Production note about ExternalSecrets

### 6. Updated Doc: Backup Demo (`docs/03-backup-demo.md`)

Add "Database Backups" section:
- Two backup systems explained (PVC vs DB)
- PVC auto-restores; DB requires manual recovery
- Link to cnpg-disaster-recovery.md

### 7. Updated Doc: Architecture (`docs/architecture.md`)

Add database backup path to architecture overview alongside PVC backup path.

### 8. Updated: secrets/README.md

Add `cnpg-s3-credentials` to the secrets inventory.

### 9. Updated: readme.md

Mention database DR in features list, link to DR doc.

### 10. New File: CLAUDE.md

Starter-kit version covering:
- Project overview (YouTube demo starter kit)
- Sync wave architecture
- Two backup systems (PVC + DB)
- CNPG DR pattern with serverName table
- Directory structure
- Key patterns and conventions
