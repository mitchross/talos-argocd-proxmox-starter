# Prerequisites

## Required

### 1. Kubernetes Cluster
- **Talos OS** (recommended) or any Kubernetes distribution
- Minimum 2 nodes (1 control plane + 1 worker) with 4GB RAM each
- `kubectl` configured and connected to the cluster

### 2. Cilium CNI
Cilium must be installed before bootstrapping. Install with:

```bash
cilium install \
    --version 1.19.0 \
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

> **Important**: Bootstrap with Hubble DISABLED. ArgoCD will enable it at Wave 0.
> If you enable Hubble at install time, it generates TLS certs that conflict with ArgoCD's render.

### 3. NFS Server
An NFS server accessible from all cluster nodes. This stores Kopia backup repositories.

See [01-nfs-setup.md](01-nfs-setup.md) for setup guides.

**Required NFS exports:**
- A directory for VolSync backups (e.g., `/mnt/backup/volsync`)
- Writable by UID 568 (VolSync mover user)

### 4. Helm CLI
```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 5. Gateway API CRDs
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
```

## Configuration

Before deploying, search for `CHANGE` comments and update:

| What | Where | Example |
|------|-------|---------|
| NFS server IP | `pvc-plumber/deployment.yaml`, `kyverno/policies/volsync-nfs-inject.yaml` | `192.168.1.100` |
| NFS backup path | Same files | `/mnt/backup/volsync` |
| Git repo URL | All files in `argocd/apps/` | `https://github.com/you/your-repo.git` |
| Domain name | `gateway/gw-*.yaml` | `*.demo.example.com` |
| Cilium IP pool | `cilium/ip-pool.yaml` | `192.168.1.32/27` |
| Gateway IP | `gateway/gw-internal.yaml` | `192.168.1.50` |
| Secrets | `secrets/*.yaml` | Replace all `CHANGE-ME` values |
