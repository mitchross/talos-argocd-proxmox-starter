# Secrets Setup

Run these commands before `./scripts/bootstrap-argocd.sh`.

## 1. Create namespaces

```bash
kubectl create namespace volsync-system
kubectl create namespace cloudnative-pg
kubectl create namespace immich
kubectl create namespace karakeep
kubectl create namespace cloudflared
kubectl create namespace external-dns
```

## 2. Cloudflared Tunnel Token

1. Go to https://one.dash.cloudflare.com → Networks → Tunnels → **Create a tunnel**
2. Choose **Cloudflared** connector type, name your tunnel
3. Copy the token (the long base64 string from the install command)

```bash
kubectl create secret generic cloudflared-token --namespace cloudflared --from-literal=token='YOUR-TUNNEL-TOKEN-HERE'
```

Then configure one public hostname in the tunnel dashboard:
- Subdomain: `*`, Domain: `yourdomain.com`
- Service Type: **HTTPS**
- URL: `cilium-gateway-gateway-external.gateway.svc.cluster.local:443`
- Additional application settings → TLS → **No TLS Verify**: ON

ExternalDNS handles creating individual DNS records automatically from your HTTPRoutes.

## 3. Cloudflare API Token (for ExternalDNS)

1. Go to https://dash.cloudflare.com → Profile (top-right) → **API Tokens** → **Create Token**
2. Use the **"Edit zone DNS"** template
3. Set permissions:
   - Zone / DNS / Edit
   - Zone / Zone / Read
4. Zone Resources: Include → Specific zone → **your domain**
5. Click Create Token and copy it

```bash
kubectl create secret generic cloudflare-api-token --namespace external-dns --from-literal=api-token='YOUR-CLOUDFLARE-API-TOKEN'
```

## 4. Kopia Backup Password

```bash
kubectl create secret generic kopia-credentials --namespace volsync-system --from-literal=KOPIA_PASSWORD="$(openssl rand -base64 32)"
```

## 5. Immich Database Credentials

Same password must be in both namespaces:

```bash
DB_PASSWORD=$(openssl rand -base64 32)
kubectl create secret generic immich-app-secret --namespace cloudnative-pg --from-literal=username='immich' --from-literal=password="$DB_PASSWORD"
kubectl create secret generic immich-db-credentials --namespace immich --from-literal=username='immich' --from-literal=password="$DB_PASSWORD"
```

## 6. CNPG S3 Credentials (for database backups)

```bash
kubectl create secret generic cnpg-s3-credentials --namespace cloudnative-pg --from-literal=AWS_ACCESS_KEY_ID='your-access-key' --from-literal=AWS_SECRET_ACCESS_KEY='your-secret-key'
```

## 7. Karakeep Secrets

```bash
kubectl create secret generic karakeep-secret --namespace karakeep --from-literal=NEXTAUTH_SECRET="$(openssl rand -base64 32)" --from-literal=MEILI_MASTER_KEY="$(openssl rand -base64 32)"
```

## Then bootstrap

```bash
./scripts/bootstrap-argocd.sh
```
