# Secrets

These secrets must be applied **before** bootstrapping ArgoCD.

## Instructions

1. Edit each file below and replace `CHANGE-ME` values with real credentials
2. Apply them to your cluster:

```bash
# Kopia encryption password (used by VolSync + PVC Plumber)
kubectl apply -f secrets/kopia-credentials.yaml

# Immich database credentials (used by CNPG and Immich server)
kubectl apply -f secrets/immich-db-init-secret.yaml
kubectl apply -f secrets/immich-db-credentials.yaml

# Karakeep application secrets
kubectl apply -f secrets/karakeep-secret.yaml

# CNPG database backup credentials (S3 access for Barman backups)
kubectl apply -f secrets/cnpg-s3-credentials.yaml
```

## Secret Details

| Secret | Namespace | Used By |
|--------|-----------|---------|
| `kopia-credentials` | `volsync-system` | PVC Plumber + Kyverno (cloned to app namespaces) |
| `immich-app-secret` | `cloudnative-pg` | CNPG cluster bootstrap (DB owner credentials) |
| `immich-db-credentials` | `immich` | Immich server (connects to DB) |
| `karakeep-secret` | `karakeep` | Karakeep web app (NextAuth, Meili keys) |
| `cnpg-s3-credentials` | `cloudnative-pg` | CNPG Barman backup (S3 access for database backups) |

## Important

- The `kopia-credentials` secret is the **source of truth** for all backup encryption.
  Kyverno automatically clones this password into per-PVC secrets in each app namespace.
- Use the **same password** for Kopia across all environments if you want cross-cluster restore.
- Never commit real secret values to Git.
- For production, consider replacing plain Secrets with ExternalSecret (1Password) or SealedSecret for automated credential rotation.
