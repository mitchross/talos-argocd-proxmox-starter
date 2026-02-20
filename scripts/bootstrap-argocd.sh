#!/usr/bin/env bash
set -euo pipefail

# Bootstrap ArgoCD Script
# Installs ArgoCD via Helm, then applies the root Application
# which triggers the full GitOps sync wave chain.
#
# Prerequisites:
#   1. Cilium installed (correct version)
#   2. 1Password Connect bootstrap secrets created (see secrets-example.md)

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

# Check Cilium version matches expected
# Version mismatch causes ArgoCD to upgrade Cilium at Wave 0, which can
# corrupt BPF state and cause Hubble TLS cert mismatches.
RUNNING_VERSION=$(cilium version 2>/dev/null | sed -nE 's/.*cilium image.*: v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1)
if [ -n "$RUNNING_VERSION" ] && [ "$RUNNING_VERSION" != "$EXPECTED_CILIUM_VERSION" ]; then
  echo "WARNING: Cilium version mismatch!"
  echo "  Running:  $RUNNING_VERSION"
  echo "  Expected: $EXPECTED_CILIUM_VERSION"
  echo ""
  echo "  Version mismatch causes ArgoCD to upgrade Cilium at Wave 0,"
  echo "  which can corrupt BPF state and break Hubble TLS certs."
  echo ""
  read -rp "  Continue anyway? (y/N) " response
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "Aborted. Reinstall Cilium with version $EXPECTED_CILIUM_VERSION"
    exit 1
  fi
fi

echo "OK: Cilium is healthy (version: ${RUNNING_VERSION:-unknown})"

# Pre-flight: Verify 1Password Connect bootstrap secrets exist
echo ""
echo "--- Pre-flight: Checking 1Password bootstrap secrets ---"

MISSING_SECRETS=0

# Create namespaces for 1Password Connect + ESO
kubectl create namespace 1passwordconnect --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

if ! kubectl get secret 1password-credentials -n 1passwordconnect &> /dev/null; then
  echo "MISSING: 1password-credentials in 1passwordconnect"
  echo "  See secrets-example.md for setup instructions"
  MISSING_SECRETS=1
fi

if ! kubectl get secret 1password-operator-token -n 1passwordconnect &> /dev/null; then
  echo "MISSING: 1password-operator-token in 1passwordconnect"
  echo "  See secrets-example.md for setup instructions"
  MISSING_SECRETS=1
fi

if ! kubectl get secret 1passwordconnect -n external-secrets &> /dev/null; then
  echo "MISSING: 1passwordconnect in external-secrets"
  echo "  See secrets-example.md for setup instructions"
  MISSING_SECRETS=1
fi

if [ $MISSING_SECRETS -eq 1 ]; then
  echo ""
  echo "ERROR: Missing 1Password bootstrap secrets."
  echo "These are the only secrets you need to create manually."
  echo "All other secrets are pulled from 1Password automatically via External Secrets Operator."
  echo ""
  echo "See secrets-example.md for setup instructions."
  exit 1
fi

echo "OK: 1Password bootstrap secrets found"

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
echo "  Wave 0: Cilium (networking), 1Password Connect, External Secrets Operator"
echo "  Wave 1: Longhorn (storage), Snapshot Controller, VolSync"
echo "  Wave 2: PVC Plumber (backup checker, FAIL-CLOSED gate)"
echo "  Wave 3: Kyverno (policy engine)"
echo "  Wave 4: CNPG Operator (database CRDs)"
echo "  Wave 5: Infrastructure AppSet (gateway, cloudflared, external-dns, NFS CSI, CNPG clusters)"
echo "  Wave 7: My-Apps AppSet (Immich, Karakeep)"
echo ""
echo "All application secrets are managed by External Secrets Operator (1Password)."
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
