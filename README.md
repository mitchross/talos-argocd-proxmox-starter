# Intent-Based Data Protection with Kyverno & VolSync

**Zero-touch, policy-driven backup and recovery for Kubernetes stateful workloads.**

> Add `backup: "hourly"` to a PVC label. That's it. Kyverno generates the backup schedule, credentials, and restore capability automatically. If the cluster is rebuilt, data restores on PVC creation — no manual intervention.

## How It Works

```
Developer adds label          Kyverno generates           VolSync executes
┌──────────────────┐    ┌────────────────────────┐    ┌──────────────────┐
│ PVC with          │───>│ Secret (Kopia creds)   │───>│ Hourly snapshots  │
│ backup: "hourly" │    │ ReplicationSource      │    │ Kopia compress    │
│                  │    │ ReplicationDestination  │    │ Push to NFS       │
└──────────────────┘    └────────────────────────┘    └──────────────────┘

On disaster recovery:
┌──────────────────┐    ┌────────────────────────┐    ┌──────────────────┐
│ PVC recreated     │───>│ PVC Plumber: backup    │───>│ VolSync restores  │
│ (same name+label) │    │ exists? YES            │    │ from NFS          │
│                  │    │ Kyverno adds           │    │ PVC = restored    │
│                  │    │ dataSourceRef          │    │ data              │
└──────────────────┘    └────────────────────────┘    └──────────────────┘
```

## Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| **ArgoCD** | 8.3.0 | GitOps self-management |
| **Cilium** | 1.19.0 | CNI + Gateway API + L2 LB |
| **Longhorn** | 1.11.0 | Block storage + snapshots |
| **Kyverno** | 3.7.0 | Policy engine (backup automation) |
| **VolSync** | 0.18.2 | Async data replication (Kopia) |
| **PVC Plumber** | 1.1.0 | Backup existence checker |
| **CNPG** | 0.27.1 | PostgreSQL operator |
| **Barman** | (built-in) | Database backup to S3 |

## Demo Applications

| App | Description | PVCs with Backup |
|-----|-------------|------------------|
| **Immich** | Photo management (server + ML + Postgres) | `library` (hourly) |
| **Karakeep** | Bookmark manager (web + Meilisearch + Chrome) | `data-pvc` (hourly), `meilisearch-pvc` (hourly) |

## Quick Start

### 1. Prerequisites
- Kubernetes cluster (Talos OS recommended)
- NFS server ([setup guide](docs/01-nfs-setup.md))
- Cilium CLI, Helm CLI, kubectl

### 2. Configure
```bash
git clone https://github.com/mitchross/talos-argocd-proxmox-starter.git
cd talos-argocd-proxmox-starter

# Find all values you need to change
grep -rn "CHANGE" --include="*.yaml" .
```

### 3. Deploy
```bash
# Install Cilium
cilium install --version 1.19.0 \
    --set cluster.name=demo-cluster \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set hubble.enabled=false \
    --set gatewayAPI.enabled=true

# Apply secrets
kubectl apply -f secrets/

# Bootstrap ArgoCD
./scripts/bootstrap-argocd.sh

# Watch applications deploy in wave order
kubectl get applications -n argocd -w
```

### 4. Verify Backups
```bash
# Check Kyverno generated backup resources
kubectl get replicationsource,replicationdestination -A

# Check PVC Plumber health
kubectl get pods -n volsync-system -l app.kubernetes.io/name=pvc-plumber
```

## Sync Wave Architecture

```
Wave 0: Cilium (networking)
Wave 1: Longhorn + VolSync + Snapshot Controller (storage)
Wave 2: PVC Plumber (backup checker - FAIL-CLOSED gate)
Wave 3: Kyverno (policy engine - webhooks must register before app PVCs)
Wave 4: Infrastructure AppSet (gateway, NFS CSI, CNPG databases)
Wave 6: My-Apps AppSet (Immich, Karakeep - PVCs trigger Kyverno)
```

## Documentation

| Doc | Description |
|-----|-------------|
| [Prerequisites](docs/00-prerequisites.md) | What you need before starting |
| [NFS Setup](docs/01-nfs-setup.md) | Setting up NFS on Ubuntu, TrueNAS, Synology, Windows |
| [Bootstrap Guide](docs/02-bootstrap.md) | Step-by-step deployment |
| [Backup Demo](docs/03-backup-demo.md) | Walk through the backup pipeline |
| [Restore Demo](docs/04-restore-demo.md) | Simulate disaster recovery with auto-restore |
| [Architecture](docs/architecture.md) | System design and component interactions |
| [CNPG Disaster Recovery](docs/cnpg-disaster-recovery.md) | Database backup and recovery procedures |

## Directory Structure

```
infrastructure/
├── controllers/
│   ├── argocd/          # ArgoCD + root app + sync wave Applications
│   ├── kyverno/         # Policy engine + 3 backup policies
│   └── pvc-plumber/     # Backup existence checker
├── database/
│   └── cnpg/            # CloudNativePG operator + Immich Postgres cluster
├── networking/
│   ├── cilium/          # CNI + L2 announcements
│   └── gateway/         # Gateway API (external + internal)
└── storage/
    ├── longhorn/        # Block storage + VolumeSnapshotClass
    ├── volsync/         # Backup operator + VolumeSnapshotClass
    ├── snapshot-controller/  # VolumeSnapshot CRDs
    └── csi-driver-nfs/  # NFS CSI driver

my-apps/
└── media/
    ├── immich/          # Photo management
    └── karakeep/        # Bookmark manager

secrets/                 # Template secrets (CHANGE-ME values)
docs/                    # Setup guides and demos
scripts/                 # Bootstrap automation
```

## License

MIT
