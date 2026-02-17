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
| **Cloudflared** | latest | Cloudflare tunnel for external access |
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
- Cloudflare account + domain ([tunnel setup](secrets-example.md#2-cloudflared-tunnel-credentials))
- Cilium CLI, Helm CLI, kubectl

### 2. Clone & Configure
```bash
git clone https://github.com/mitchross/talos-argocd-proxmox-starter.git
cd talos-argocd-proxmox-starter

# Find all values you need to change
grep -rn "CHANGE" --include="*.yaml" .
```

Key values to set:
- `infrastructure/networking/cilium/values.yaml` — cluster name, API server IP
- `infrastructure/networking/cilium/ip-pool.yaml` — LoadBalancer IP range
- `infrastructure/networking/cloudflared/config.yaml` — tunnel name, domain
- `infrastructure/networking/gateway/gw-external.yaml` — domain
- `infrastructure/networking/gateway/gw-internal.yaml` — IP, domain
- `infrastructure/controllers/kyverno/policies/volsync-nfs-inject.yaml` — NFS server IP/path
- `infrastructure/controllers/pvc-plumber/deployment.yaml` — NFS server IP/path
- All files in `infrastructure/controllers/argocd/apps/` — Git repo URL

### 3. Install Cilium
```bash
cilium install --version 1.19.0 \
    --set cluster.name=demo-cluster \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set hubble.enabled=false \
    --set hubble.relay.enabled=false \
    --set hubble.ui.enabled=false \
    --set gatewayAPI.enabled=true
```

### 4. Create Secrets

Secrets must exist before ArgoCD deploys the apps that reference them.

See [secrets-example.md](secrets-example.md) for full instructions, or the quick version:

```bash
# Create namespaces
kubectl create namespace volsync-system
kubectl create namespace cloudnative-pg
kubectl create namespace immich
kubectl create namespace karakeep
kubectl create namespace cloudflared

# Cloudflared tunnel credentials
# (requires: cloudflared tunnel login && cloudflared tunnel create my-tunnel)
kubectl create secret generic tunnel-credentials \
  --namespace cloudflared \
  --from-file=credentials.json=$HOME/.cloudflared/<TUNNEL-ID>.json

# Kopia backup encryption password
KOPIA_PASSWORD=$(openssl rand -base64 32)
kubectl create secret generic kopia-credentials \
  --namespace volsync-system \
  --from-literal=KOPIA_PASSWORD="$KOPIA_PASSWORD"

# Immich database credentials (same password in both namespaces)
DB_PASSWORD=$(openssl rand -base64 32)
kubectl create secret generic immich-app-secret \
  --namespace cloudnative-pg \
  --from-literal=username='immich' \
  --from-literal=password="$DB_PASSWORD"
kubectl create secret generic immich-db-credentials \
  --namespace immich \
  --from-literal=username='immich' \
  --from-literal=password="$DB_PASSWORD"

# CNPG S3 credentials (for database backups)
kubectl create secret generic cnpg-s3-credentials \
  --namespace cloudnative-pg \
  --from-literal=AWS_ACCESS_KEY_ID='your-access-key' \
  --from-literal=AWS_SECRET_ACCESS_KEY='your-secret-key'

# Karakeep secrets
kubectl create secret generic karakeep-secret \
  --namespace karakeep \
  --from-literal=NEXTAUTH_SECRET="$(openssl rand -base64 32)" \
  --from-literal=MEILI_MASTER_KEY="$(openssl rand -base64 32)"
```

### 5. Bootstrap ArgoCD
```bash
# Bootstrap (pre-flight checks verify Cilium + secrets exist)
./scripts/bootstrap-argocd.sh

# Watch applications deploy in wave order
kubectl get applications -n argocd -w
```

### 6. Verify Backups
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
Wave 4: CNPG Operator (database CRDs)
Wave 5: Infrastructure AppSet (gateway, cloudflared, NFS CSI, CNPG clusters)
Wave 7: My-Apps AppSet (Immich, Karakeep - PVCs trigger Kyverno)
```

## Documentation

| Doc | Description |
|-----|-------------|
| [Secrets Setup](secrets-example.md) | How to create all required secrets |
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
│   ├── cloudflared/     # Cloudflare tunnel
│   └── gateway/         # Gateway API (external + internal)
└── storage/
    ├── longhorn/        # Block storage
    ├── volsync/         # Backup operator + VolumeSnapshotClass
    ├── snapshot-controller/  # VolumeSnapshot CRDs
    └── csi-driver-nfs/  # NFS CSI driver

my-apps/
└── media/
    ├── immich/          # Photo management
    └── karakeep/        # Bookmark manager

secrets-example.md       # How to create secrets (committed)
secrets.md               # Your actual secret values (gitignored)
docs/                    # Setup guides and demos
scripts/                 # Bootstrap automation
```

## License

MIT
