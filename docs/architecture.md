# Architecture: Intent-Based Data Protection

## The Problem

Every Kubernetes app with persistent data needs backup configuration:
- ReplicationSource (schedule, retention, backend)
- Secrets (repository credentials)
- ReplicationDestination (restore capability)

That's 3+ manifests per PVC, manually maintained. When you have 10+ apps, it's unsustainable.

## The Solution: One Label = Full Backup

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-data
  labels:
    backup: "hourly"   # <-- This is all you write
spec:
  storageClassName: longhorn
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
```

Kyverno detects this label and **automatically generates**:
1. A Secret with Kopia credentials (cloned from a source secret)
2. A ReplicationSource (backup schedule + retention policy)
3. A ReplicationDestination (restore capability)

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  PVC with backup: "hourly"              │
└────────────────────────┬────────────────────────────────┘
                         │ CREATE
                         ▼
┌─────────────────────────────────────────────────────────┐
│              KYVERNO ADMISSION WEBHOOK                  │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Rule 0 (Validate): Is PVC Plumber healthy?             │
│    └─ NO  → DENY PVC creation (fail-closed)             │
│    └─ YES → continue                                    │
│                                                         │
│  Rule 1 (Mutate): Does backup exist?                    │
│    └─ YES → Add dataSourceRef (auto-restore!)           │
│    └─ NO  → Pass through (fresh volume)                 │
│                                                         │
│  Rules 2-4 (Generate): Create Secret +                  │
│    ReplicationSource + ReplicationDestination            │
│                                                         │
└────────────────────────┬────────────────────────────────┘
                         │
              ┌──────────┼──────────┐
              ▼          ▼          ▼
         [Restore]  [Fresh PVC]  [Backup Resources]
              │          │          │
              ▼          ▼          ▼
         VolSync     Longhorn    On Schedule:
         restores    creates     VolSync mover pod
         from NFS    empty vol   → Longhorn snapshot
                                 → Kopia compress+encrypt
                                 → Push to NFS
```

## Sync Wave Order

| Wave | Component | Why |
|------|-----------|-----|
| 0 | Cilium | Networking must exist first |
| 1 | Longhorn, VolSync, Snapshot Controller | Storage layer |
| 2 | PVC Plumber | Must run before Kyverno policies call it |
| 3 | Kyverno | Webhooks must register before apps create PVCs |
| 4 | Infrastructure AppSet | Gateway, NFS CSI, CNPG databases |
| 6 | My-Apps AppSet | Immich, Karakeep (PVCs trigger Kyverno) |

## The Four Scenarios

### 1. Fresh Deploy (No Backups Exist)
PVC Plumber returns `exists: false` → Longhorn creates empty volume → App starts fresh → Backups begin after 2 hours

### 2. Disaster Recovery (Backups Exist)
PVC Plumber returns `exists: true` → Kyverno adds dataSourceRef → VolSync restores from NFS → App starts with all data

### 3. PVC Plumber Down
PVC Plumber unreachable → Kyverno DENIES PVC creation → ArgoCD retries with backoff → Once Plumber healthy, restore proceeds

### 4. Disable Backup
Remove `backup` label from PVC → Orphan cleanup runs (15min) → Deletes ReplicationSource/Destination/Secret → Backups stop, data on NFS retained

## Components

| Component | Image | Purpose |
|-----------|-------|---------|
| **Kyverno** | `kyverno/kyverno:3.7.0` | Policy engine, generates backup resources |
| **VolSync** | `ghcr.io/perfectra1n/volsync:0.17.7` | Data mover, executes backups/restores |
| **PVC Plumber** | `ghcr.io/mitchross/pvc-plumber:1.1.0` | Checks Kopia repo for existing backups |
| **Kopia** | (embedded in VolSync) | Dedup, compress, encrypt backup data |
| **Longhorn** | `longhornio/longhorn:1.11.0` | Block storage with snapshot support |

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
