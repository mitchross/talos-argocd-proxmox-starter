#!/usr/bin/env bash
set -euo pipefail

# Bootstrap ArgoCD Script
# Installs ArgoCD via Helm, then applies the root Application
# which triggers the full GitOps sync wave chain.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Expected Cilium version — must match infrastructure/networking/cilium/kustomization.yaml
EXPECTED_CILIUM_VERSION="1.19.0"

echo "=== Bootstrapping ArgoCD with sync waves ==="

# Pre-flight: Verify Cilium is installed and healthy
echo ""
echo "--- Pre-flight: Checking Cilium ---"

if ! command -v cilium &> /dev/null; then
  echo "ERROR: cilium CLI not found. Install it first:"
  echo "  https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/"
  exit 1
fi

if ! cilium status --wait --wait-duration 30s &> /dev/null; then
  echo "ERROR: Cilium is not healthy. Install Cilium first:"
  echo ""
  echo "  cilium install \\"
  echo "      --version $EXPECTED_CILIUM_VERSION \\"
  echo "      --set cluster.name=demo-cluster \\"
  echo "      --set ipam.mode=kubernetes \\"
  echo "      --set kubeProxyReplacement=true \\"
  echo "      --set k8sServiceHost=localhost \\"
  echo "      --set k8sServicePort=7445 \\"
  echo "      --set hubble.enabled=false \\"
  echo "      --set hubble.relay.enabled=false \\"
  echo "      --set hubble.ui.enabled=false \\"
  echo "      --set gatewayAPI.enabled=true"
  echo ""
  exit 1
fi

echo "OK: Cilium is healthy"

# Pre-flight: Verify secrets exist
echo ""
echo "--- Pre-flight: Checking secrets ---"

MISSING_SECRETS=0

# Check namespaces exist (create if needed)
kubectl create namespace volsync-system --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
kubectl create namespace cloudnative-pg --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
kubectl create namespace immich --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
kubectl create namespace karakeep --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
kubectl create namespace cloudflared --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

if ! kubectl get secret kopia-credentials -n volsync-system &> /dev/null; then
  echo "MISSING: kopia-credentials in volsync-system"
  echo "  Apply: kubectl apply -f secrets/kopia-credentials.yaml"
  MISSING_SECRETS=1
fi

if ! kubectl get secret immich-app-secret -n cloudnative-pg &> /dev/null; then
  echo "MISSING: immich-app-secret in cloudnative-pg"
  echo "  Apply: kubectl apply -f secrets/immich-db-init-secret.yaml"
  MISSING_SECRETS=1
fi

if ! kubectl get secret cnpg-s3-credentials -n cloudnative-pg &> /dev/null; then
  echo "MISSING: cnpg-s3-credentials in cloudnative-pg"
  echo "  Apply: kubectl apply -f secrets/cnpg-s3-credentials.yaml"
  MISSING_SECRETS=1
fi

if ! kubectl get secret immich-db-credentials -n immich &> /dev/null; then
  echo "MISSING: immich-db-credentials in immich"
  echo "  Apply: kubectl apply -f secrets/immich-db-credentials.yaml"
  MISSING_SECRETS=1
fi

if ! kubectl get secret karakeep-secret -n karakeep &> /dev/null; then
  echo "MISSING: karakeep-secret in karakeep"
  echo "  Apply: kubectl apply -f secrets/karakeep-secret.yaml"
  MISSING_SECRETS=1
fi

if ! kubectl get secret cloudflared-token -n cloudflared &> /dev/null; then
  echo "MISSING: cloudflared-token in cloudflared"
  echo "  See secrets-example.md for setup instructions"
  MISSING_SECRETS=1
fi

if ! kubectl get secret cloudflare-api-token -n external-dns &> /dev/null; then
  echo "MISSING: cloudflare-api-token in external-dns"
  echo "  See secrets-example.md for setup instructions"
  MISSING_SECRETS=1
fi

if [ $MISSING_SECRETS -eq 1 ]; then
  echo ""
  echo "ERROR: Missing secrets. Apply them first (see secrets/README.md)"
  exit 1
fi

echo "OK: All secrets found"

# Step 1: Create namespace
echo ""
echo "--- Creating argocd namespace ---"
kubectl apply -f "$ROOT_DIR/infrastructure/controllers/argocd/ns.yaml"

# Step 2: Install ArgoCD using Helm
echo ""
echo "--- Installing ArgoCD via Helm ---"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version 8.3.0 \
  --namespace argocd \
  --values "$ROOT_DIR/infrastructure/controllers/argocd/values.yaml" \
  --wait \
  --timeout 10m

# Step 3: Wait for CRDs
echo ""
echo "--- Waiting for ArgoCD CRDs ---"
kubectl wait --for condition=established --timeout=60s crd/applications.argoproj.io

# Step 4: Wait for server
echo ""
echo "--- Waiting for ArgoCD server ---"
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s

# Step 5: Apply root application
echo ""
echo "--- Deploying root application (enables self-management) ---"
kubectl apply -f "$ROOT_DIR/infrastructure/controllers/argocd/root.yaml"

echo ""
echo "=== ArgoCD bootstrap complete! ==="
echo ""
echo "Sync wave order:"
echo "  Wave 0: Cilium (networking)"
echo "  Wave 1: Longhorn (storage), Snapshot Controller, VolSync"
echo "  Wave 2: PVC Plumber (backup checker, FAIL-CLOSED gate)"
echo "  Wave 3: Kyverno (policy engine)"
echo "  Wave 4: CNPG Operator (database CRDs)"
echo "  Wave 5: Infrastructure AppSet (gateway, cloudflared, external-dns, NFS CSI, CNPG clusters)"
echo "  Wave 7: My-Apps AppSet (Immich, Karakeep)"
echo ""
echo "Monitor progress:"
echo "  kubectl get applications -n argocd -w"
echo ""
echo "Access ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  https://localhost:8080"
echo ""
echo "Get admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
