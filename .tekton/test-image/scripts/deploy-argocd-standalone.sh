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

# OpenShift-specific fixes
echo "Applying OpenShift-specific patches..."

# Create argocd-redis secret if it doesn't exist (required by pods for redis password)
if ! oc get secret argocd-redis -n "$NAMESPACE" &>/dev/null; then
    echo "  Creating argocd-redis secret..."
    oc create secret generic argocd-redis \
      --from-literal=auth="" \
      -n "$NAMESPACE"
fi

# Grant anyuid SCC to service accounts to allow running as UID 999
# Upstream ArgoCD manifests use hardcoded UIDs that don't match OpenShift's allocated ranges
echo "  Granting anyuid SCC to ArgoCD service accounts..."
for sa in argocd-application-controller argocd-server argocd-repo-server argocd-dex-server argocd-redis; do
    oc adm policy add-scc-to-user anyuid -z "$sa" -n "$NAMESPACE" 2>/dev/null || true
done

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

# Extract admin password
ADMIN_PASSWORD=$(oc get secret argocd-initial-admin-secret -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

if [ -z "$ADMIN_PASSWORD" ]; then
  echo "WARNING: Could not extract admin password from argocd-initial-admin-secret"
  # Try cluster secret (some ArgoCD versions use this)
  ADMIN_PASSWORD=$(oc get secret argocd-cluster -n "$NAMESPACE" -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d || echo "password")
fi

# Get ArgoCD server service DNS name (for in-cluster access)
ARGOCD_SERVER_SERVICE="argocd-server.${NAMESPACE}.svc.cluster.local"

echo ""
echo "ArgoCD server service: ${ARGOCD_SERVER_SERVICE}"
echo "Admin username: admin"
echo "Admin password: ${ADMIN_PASSWORD:0:8}..." # Print first 8 chars only

# Write task results for use by test task
# These will be available as $(tasks.deploy-argocd.results.xxx)
if [ -d /tekton/results ]; then
  echo -n "$NAMESPACE" > /tekton/results/namespace
  echo -n "$ARGOCD_SERVER_SERVICE" > /tekton/results/server
  echo -n "$ADMIN_PASSWORD" > /tekton/results/adminPassword
  echo -n "argocd-server" > /tekton/results/serverName
  echo -n "argocd-repo-server" > /tekton/results/repoServerName
  echo -n "argocd-application-controller" > /tekton/results/applicationControllerName
  echo -n "argocd-redis" > /tekton/results/redisName

  echo "Task results written to /tekton/results/"
fi
