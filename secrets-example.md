# Secrets Setup

Run these commands before `./scripts/bootstrap-argocd.sh`.

## 1. Create namespaces first

```bash
kubectl create namespace volsync-system
kubectl create namespace cloudnative-pg
kubectl create namespace immich
kubectl create namespace karakeep
kubectl create namespace cloudflared
```

## 2. Cloudflared Tunnel Credentials

### Create a tunnel

```bash
# Install cloudflared CLI
brew install cloudflared        # macOS
# or: sudo apt install cloudflared  # Ubuntu/Debian

# Login to Cloudflare (opens browser)
cloudflared tunnel login

# Create a tunnel
cloudflared tunnel create my-tunnel
# Output: Created tunnel my-tunnel with id <TUNNEL-ID>
# Saves credentials to: ~/.cloudflared/<TUNNEL-ID>.json

# Create DNS route (wildcard)
cloudflared tunnel route dns my-tunnel "*.yourdomain.com"
```

### Update config.yaml

Edit `infrastructure/networking/cloudflared/config.yaml`:
- Set `tunnel:` to your tunnel name
- Set hostnames to `*.yourdomain.com`

### Create the secret

The credentials JSON file (saved at `~/.cloudflared/<TUNNEL-ID>.json`) looks like this:

```json
{
  "AccountTag": "0cd4390209a0adbc162c9bf21771d71",
  "TunnelSecret": "YjAzMjllNmQtNDE4Mi00MzYwLWI4YTItYmQxOWQ3N2IwMmQz",
  "TunnelID": "cb12653d-ae9a-41cb-96b3-2f5ce34f088f"
}
```

- **AccountTag**: Your Cloudflare account ID (found in dashboard URL or API)
- **TunnelSecret**: Auto-generated base64 secret (created by `cloudflared tunnel create`)
- **TunnelID**: The tunnel UUID (matches the JSON filename)

```bash
kubectl create secret generic tunnel-credentials \
  --namespace cloudflared \
  --from-file=credentials.json=$HOME/.cloudflared/<TUNNEL-ID>.json
```

## 3. Kopia Backup Password

```bash
KOPIA_PASSWORD=$(openssl rand -base64 32)

kubectl create secret generic kopia-credentials \
  --namespace volsync-system \
  --from-literal=KOPIA_PASSWORD="$KOPIA_PASSWORD"

echo "Save this password: $KOPIA_PASSWORD"
```

## 4. Immich Database Credentials

Use the same password in both secrets:

```bash
DB_PASSWORD=$(openssl rand -base64 32)

# CNPG bootstrap secret (operator namespace)
kubectl create secret generic immich-app-secret \
  --namespace cloudnative-pg \
  --from-literal=username='immich' \
  --from-literal=password="$DB_PASSWORD"

# App-side credentials (immich namespace)
kubectl create secret generic immich-db-credentials \
  --namespace immich \
  --from-literal=username='immich' \
  --from-literal=password="$DB_PASSWORD"

echo "Save this password: $DB_PASSWORD"
```

## 5. CNPG S3 Credentials (for database backups)

```bash
kubectl create secret generic cnpg-s3-credentials \
  --namespace cloudnative-pg \
  --from-literal=AWS_ACCESS_KEY_ID='your-s3-access-key' \
  --from-literal=AWS_SECRET_ACCESS_KEY='your-s3-secret-key'
```

## 6. Karakeep Secrets

```bash
NEXTAUTH_SECRET=$(openssl rand -base64 32)
MEILI_MASTER_KEY=$(openssl rand -base64 32)

kubectl create secret generic karakeep-secret \
  --namespace karakeep \
  --from-literal=NEXTAUTH_SECRET="$NEXTAUTH_SECRET" \
  --from-literal=MEILI_MASTER_KEY="$MEILI_MASTER_KEY"
```

## Then bootstrap

```bash
./scripts/bootstrap-argocd.sh
```
