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
| **1Password Connect** | 2.3.0 | Secret provider |
| **External Secrets** | 2.0.0 | Pulls secrets from 1Password into K8s |
| **Longhorn** | 1.11.0 | Block storage + snapshots |
| **Kyverno** | 3.7.0 | Policy engine (backup automation) |
| **VolSync** | 0.18.2 | Async data replication (Kopia) |
| **PVC Plumber** | 1.1.0 | Backup existence checker |
| **CNPG** | 0.27.1 | PostgreSQL operator |
| **Cloudflared** | latest | Cloudflare tunnel for external access |
| **ExternalDNS** | 1.20.0 | Auto-creates Cloudflare DNS records |
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
- 1Password account ([secret setup](secrets-example.md))
- Cloudflare account + domain
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
- `infrastructure/networking/gateway/gw-external.yaml` — domain
- `infrastructure/networking/gateway/gw-internal.yaml` — IP, domain
- `infrastructure/controllers/external-dns/values.yaml` — domain filter
- `infrastructure/controllers/external-secrets/cluster-secret-store.yaml` — 1Password vault name
- `infrastructure/controllers/kyverno/policies/volsync-nfs-inject.yaml` — NFS server IP/path
- `infrastructure/controllers/pvc-plumber/deployment.yaml` — NFS server IP/path
- All files in `infrastructure/controllers/argocd/apps/` — Git repo URL
- All `externalsecret.yaml` files — 1Password item names (see [secrets-example.md](secrets-example.md))

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

### 4. Create 1Password Items & Bootstrap Secrets

All secrets are managed by **1Password + External Secrets Operator**. You only create 3 bootstrap secrets manually:

```bash
# See secrets-example.md for full 1Password item setup

kubectl create namespace 1passwordconnect
kubectl create namespace external-secrets

# 1Password Connect server credentials
kubectl create secret generic 1password-credentials \
  --namespace 1passwordconnect \
  --from-file=1password-credentials.json=/path/to/1password-credentials.json

# 1Password operator token (same access token, for the K8s operator)
kubectl create secret generic 1password-operator-token \
  --namespace 1passwordconnect \
  --from-literal=token='YOUR-1PASSWORD-CONNECT-ACCESS-TOKEN'

# ESO connect token (same access token, for External Secrets Operator)
kubectl create secret generic 1passwordconnect \
  --namespace external-secrets \
  --from-literal=token='YOUR-1PASSWORD-CONNECT-ACCESS-TOKEN'
```

### 5. Bootstrap ArgoCD
```bash
# Bootstrap (pre-flight checks verify Cilium + 1Password secrets exist)
./scripts/bootstrap-argocd.sh

# Watch applications deploy in wave order
kubectl get applications -n argocd -w
```

### 6. Verify

```bash
# Check all secrets are syncing from 1Password
kubectl get externalsecret -A

# Check Kyverno generated backup resources
kubectl get replicationsource,replicationdestination -A

# Check PVC Plumber health
kubectl get pods -n volsync-system -l app.kubernetes.io/name=pvc-plumber
```

## Sync Wave Architecture

```
Wave 0: Cilium (networking), 1Password Connect, External Secrets Operator
Wave 1: Longhorn + VolSync + Snapshot Controller (storage)
Wave 2: PVC Plumber (backup checker - FAIL-CLOSED gate)
Wave 3: Kyverno (policy engine - webhooks must register before app PVCs)
Wave 4: CNPG Operator (database CRDs)
Wave 5: Infrastructure AppSet (gateway, cloudflared, external-dns, NFS CSI, CNPG clusters)
Wave 7: My-Apps AppSet (Immich, Karakeep - PVCs trigger Kyverno)
```

## Secret Management

```
1Password Vault
    ↓
1Password Connect (Wave 0)
    ↓
ClusterSecretStore (ESO, Wave 0)
    ↓
ExternalSecret CRDs (per-component, in Git)
    ↓
Kubernetes Secrets (auto-created and synced)
    ↓
Application Pods
```

Only **3 bootstrap secrets** are created manually. Everything else is pulled from 1Password automatically. See [secrets-example.md](secrets-example.md) for setup.

## Documentation

| Doc | Description |
|-----|-------------|
| [Secrets Setup](secrets-example.md) | 1Password + ESO setup (only 2 manual secrets) |
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
│   ├── argocd/            # ArgoCD + root app + sync wave Applications
│   ├── 1passwordconnect/  # 1Password Connect server
│   ├── external-secrets/  # External Secrets Operator + ClusterSecretStore
│   ├── external-dns/      # Auto-creates Cloudflare DNS records
│   ├── kyverno/           # Policy engine + 3 backup policies
│   └── pvc-plumber/       # Backup existence checker
├── database/
│   └── cnpg/              # CloudNativePG operator + Immich Postgres cluster
├── networking/
│   ├── cilium/            # CNI + L2 announcements
│   ├── cloudflared/       # Cloudflare tunnel
│   └── gateway/           # Gateway API (external + internal)
└── storage/
    ├── longhorn/          # Block storage
    ├── volsync/           # Backup operator + VolumeSnapshotClass
    ├── snapshot-controller/  # VolumeSnapshot CRDs
    └── csi-driver-nfs/    # NFS CSI driver

my-apps/
└── media/
    ├── immich/            # Photo management
    └── karakeep/          # Bookmark manager

secrets-example.md         # 1Password setup instructions (committed)
docs/                      # Setup guides and demos
scripts/                   # Bootstrap automation
```

## License

MIT
