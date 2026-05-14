#!/bin/bash
set -euo pipefail

# Deploy ArgoCD in standalone mode (without the GitOps operator).
# Uses upstream ArgoCD manifests but overrides the server image to test a specific build.
#
# Environment variables expected:
# - ARGOCD_SERVER_IMAGE: ArgoCD server image to deploy
# - ARGOCD_VERSION: ArgoCD version for upstream manifests (default: v2.14.1)
# - NAMESPACE: Namespace to deploy ArgoCD (default: argocd)
# - KUBECONFIG: Path to kubeconfig

ARGOCD_SERVER_IMAGE="${ARGOCD_SERVER_IMAGE:?ARGOCD_SERVER_IMAGE must be set}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.14.1}"
NAMESPACE="${NAMESPACE:-argocd}"

echo "=========================================="
echo "Deploying ArgoCD standalone"
echo "=========================================="
echo "ArgoCD version: ${ARGOCD_VERSION}"
echo "Server image:   ${ARGOCD_SERVER_IMAGE}"
echo "Namespace:      ${NAMESPACE}"
echo ""

# Create namespace
echo "Creating namespace ${NAMESPACE}..."
oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# Download upstream ArgoCD manifests
echo "Downloading ArgoCD ${ARGOCD_VERSION} manifests..."
MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
curl -sSL "$MANIFEST_URL" -o /tmp/argocd-install.yaml

# Apply manifests
echo "Applying ArgoCD manifests..."
oc apply -n "$NAMESPACE" -f /tmp/argocd-install.yaml

# Patch argocd-server deployment to use custom image
echo "Patching argocd-server to use image: ${ARGOCD_SERVER_IMAGE}"
oc set image deployment/argocd-server \
  argocd-server="$ARGOCD_SERVER_IMAGE" \
  -n "$NAMESPACE"

# Wait for deployments to be ready
echo "Waiting for ArgoCD deployments to become ready..."
for deploy in argocd-server argocd-repo-server argocd-dex-server; do
  echo "  Waiting for $deploy..."
  if ! oc wait --for=condition=Available deployment/"$deploy" -n "$NAMESPACE" --timeout=10m; then
    echo "ERROR: deployment/$deploy did not become Available"
    oc get deployment "$deploy" -n "$NAMESPACE" -o wide 2>/dev/null || true
    oc get pods -n "$NAMESPACE" -o wide 2>/dev/null || true
    oc get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
    exit 1
  fi
done

# Wait for application-controller statefulset
echo "  Waiting for argocd-application-controller..."
if ! oc rollout status statefulset/argocd-application-controller -n "$NAMESPACE" --timeout=10m; then
  echo "ERROR: statefulset/argocd-application-controller did not become ready"
  oc get pods -n "$NAMESPACE" -o wide 2>/dev/null || true
  oc get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
  exit 1
fi

echo ""
echo "=========================================="
echo "ArgoCD deployed successfully"
echo "=========================================="
echo ""

# Show deployment status
oc get deployments,statefulsets,pods -n "$NAMESPACE" -o wide

# Get ArgoCD server route/service
ARGOCD_SERVER=$(oc get svc argocd-server -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || \
                oc get svc argocd-server -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || \
                echo "localhost")

echo ""
echo "ArgoCD server: ${ARGOCD_SERVER}"
echo "Admin password: Run 'oc get secret argocd-initial-admin-secret -n ${NAMESPACE} -o jsonpath={.data.password} | base64 -d'"
