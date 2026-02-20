# Secrets Setup

This cluster uses **1Password Connect + External Secrets Operator (ESO)** to automatically pull secrets from 1Password into Kubernetes. You only need to create **3 bootstrap secrets** manually — everything else is automatic.

## How It Works

```
1Password Vault
    ↓
1Password Connect Server (runs in cluster)
    ↓
ClusterSecretStore (ESO connects to 1Password Connect)
    ↓
ExternalSecret CRDs (per-app, in Git)
    ↓
Kubernetes Secrets (auto-created and synced)
```

## Prerequisites

1. **1Password account** with a vault for your homelab secrets
2. **1Password Connect server** credentials ([setup guide](https://developer.1password.com/docs/connect/get-started/))

## Step 1: Set Up 1Password Connect

1. Go to https://my.1password.com → **Integrations** → **Directory** → search **"Secrets Automation"**
2. Click **Set Up** → choose your vault → **Save**
3. Download the **1password-credentials.json** file
4. Copy the **access token** (you'll use this for ESO)

## Step 2: Create 1Password Items

Create these items in your 1Password vault. The `key` and `property` values in the ExternalSecret YAML files must match your 1Password item names and field names.

| 1Password Item | Fields | Used By |
|---------------|--------|---------|
| `cloudflared` | `token` (tunnel token) | Cloudflared tunnel |
| `cloudflare-api` | `api-token` (DNS edit token) | ExternalDNS |
| `kopia` | `password` (encryption key) | VolSync backups + PVC Plumber |
| `immich-database` | `username`, `password` | CNPG + Immich app |
| `s3-credentials` | `access-key`, `secret-key` | CNPG Barman backups |
| `karakeep` | `nextauth-secret`, `meili-master-key` | Karakeep app |

> **Tip**: For passwords like Kopia and Karakeep, generate random values:
> `openssl rand -base64 32`

> **Note**: The item names above are defaults — you can use any names as long as you update the `remoteRef.key` in the corresponding ExternalSecret YAML files. Search for `# CHANGE` markers.

## Step 3: Create Bootstrap Secrets

These are the **only** secrets you create manually. They bootstrap the 1Password Connect server and ESO:

```bash
kubectl create namespace 1passwordconnect
kubectl create namespace external-secrets

# 1Password Connect server credentials (download from 1Password integrations)
kubectl create secret generic 1password-credentials --namespace 1passwordconnect --from-file=1password-credentials.json=/path/to/1password-credentials.json

# 1Password operator token (same access token, used by the 1Password Kubernetes operator)
kubectl create secret generic 1password-operator-token --namespace 1passwordconnect --from-literal=token='YOUR-1PASSWORD-CONNECT-ACCESS-TOKEN'

# ESO connect token (same access token, used by External Secrets Operator to talk to Connect)
kubectl create secret generic 1passwordconnect --namespace external-secrets --from-literal=token='YOUR-1PASSWORD-CONNECT-ACCESS-TOKEN'
```

> **Note**: The `1password-operator-token` and `1passwordconnect` secrets use the **same** access token, just in different namespaces.

## Step 4: Bootstrap ArgoCD

```bash
./scripts/bootstrap-argocd.sh
```

The bootstrap script checks that the 3 bootstrap secrets exist, then deploys ArgoCD. ArgoCD deploys 1Password Connect + ESO at Wave 0, which then pulls all other secrets from 1Password automatically.

## Verify Secrets Are Syncing

```bash
# Check ExternalSecret status (all should show "SecretSynced")
kubectl get externalsecret -A

# Check 1Password Connect is running
kubectl get pods -n 1passwordconnect

# Check ClusterSecretStore health
kubectl get clustersecretstore 1password
```

## Troubleshooting

**ExternalSecret stuck in "SecretSyncedError"**:
```bash
kubectl describe externalsecret <name> -n <namespace>
```
Common causes:
- 1Password item name doesn't match `remoteRef.key`
- Property name doesn't match `remoteRef.property`
- 1Password Connect server not running
- Connect token expired or invalid

**1Password Connect not starting**:
```bash
kubectl logs -n 1passwordconnect -l app.kubernetes.io/name=connect
```
Common causes:
- `1password-credentials.json` is invalid or expired
- Vault name in ClusterSecretStore doesn't match your 1Password vault
