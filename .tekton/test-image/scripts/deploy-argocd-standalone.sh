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

# Let the upstream manifests run unmodified on OpenShift.
#
# Upstream's install.yaml is already hardened: non-root, all capabilities dropped, no
# privilege escalation, seccompProfile RuntimeDefault. Most components run under the default
# restricted-v2 SCC as-is. Two pin a UID outside the namespace's allocated range — dex
# (1001) and redis (999) — which restricted-v2 rejects. anyuid admits the UID but rejects the
# RuntimeDefault seccomp profile ("seccomp may not be set"), which is why granting anyuid
# only worked for a component after its seccompProfile was patched out; dex never was, and
# never became Available.
#
# nonroot-v2 admits exactly this profile — any non-root UID, runtime/default seccomp, ALL
# capabilities dropped, no privilege escalation — so no manifest needs patching. Granted to
# every ServiceAccount in the namespace, and before the manifests are applied so that the
# first pods are admitted rather than rejected and retried. Verified on FIPS OpenShift 4.22
# with Argo CD v3.5.2: dex and redis admitted under nonroot-v2, every other component under
# restricted-v2, all seven workloads ready.
echo "Granting nonroot-v2 SCC to service accounts in ${NAMESPACE}..."
oc adm policy add-scc-to-group nonroot-v2 "system:serviceaccounts:${NAMESPACE}"

# Download upstream ArgoCD manifests for the requested version
echo "Downloading ArgoCD ${ARGOCD_VERSION} manifests from upstream..."
UPSTREAM_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
curl -sSL --fail "$UPSTREAM_URL" -o /tmp/argocd-upstream.yaml

# Replace hardcoded namespace in ClusterRoleBinding subjects
sed "s/namespace: argocd/namespace: ${NAMESPACE}/g" /tmp/argocd-upstream.yaml > /tmp/argocd-install.yaml

# Apply manifests — use server-side apply to avoid the 256KB annotation limit
# on large CRDs like applicationsets.argoproj.io (hit with ArgoCD >= v3.x).
echo "Applying ArgoCD manifests to namespace ${NAMESPACE}..."
oc apply --server-side --force-conflicts -n "$NAMESPACE" -f /tmp/argocd-install.yaml

# OpenShift-specific fixes
echo "Applying OpenShift-specific patches..."

# Create argocd-redis secret with a real password (empty string causes Redis --requirepass to fail)
if ! oc get secret argocd-redis -n "$NAMESPACE" &>/dev/null; then
    echo "  Creating argocd-redis secret..."
    oc create secret generic argocd-redis \
      --from-literal=auth="argocd-e2e-redis-password" \
      -n "$NAMESPACE"
fi

# Patch argocd-server deployment to use custom image
echo "Patching argocd-server to use image: ${ARGOCD_SERVER_IMAGE}"
oc set image deployment/argocd-server \
  argocd-server="$ARGOCD_SERVER_IMAGE" \
  -n "$NAMESPACE"

# Wait for every workload the manifest created, not a hand-picked subset: a component the
# SCC rejects (as dex was) should fail the deploy here, not surface later as a test failure.
echo "Waiting for ArgoCD deployments to become ready..."
for deploy in $(oc get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
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

# Create Route to expose ArgoCD server externally (for cross-cluster access from Konflux)
echo ""
echo "Creating external Route for ArgoCD server..."
oc create route passthrough argocd-server --service=argocd-server --port=https -n "$NAMESPACE" 2>/dev/null || \
  echo "  Route already exists"

# Get external Route URL
ARGOCD_SERVER_URL=$(oc get route argocd-server -n "$NAMESPACE" -o jsonpath='{.spec.host}')

if [ -z "$ARGOCD_SERVER_URL" ]; then
  echo "ERROR: Failed to get ArgoCD server route URL"
  exit 1
fi

echo "ArgoCD server route: https://${ARGOCD_SERVER_URL}"

# Extract admin password
ADMIN_PASSWORD=$(oc get secret argocd-initial-admin-secret -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

if [ -z "$ADMIN_PASSWORD" ]; then
  echo "WARNING: Could not extract admin password from argocd-initial-admin-secret"
  # Try cluster secret (some ArgoCD versions use this)
  ADMIN_PASSWORD=$(oc get secret argocd-cluster -n "$NAMESPACE" -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d || echo "password")
fi

echo ""
echo "ArgoCD server URL: https://${ARGOCD_SERVER_URL}"
echo "Admin username: admin"
echo "Admin password: ${ADMIN_PASSWORD:0:8}..." # Print first 8 chars only

# Write task results for use by test task
# These will be available as $(tasks.deploy-argocd.results.xxx)
if [ -d /tekton/results ]; then
  echo -n "$NAMESPACE" > /tekton/results/namespace
  echo -n "$ARGOCD_SERVER_URL" > /tekton/results/server
  echo -n "$ADMIN_PASSWORD" > /tekton/results/adminPassword
  echo -n "argocd-server" > /tekton/results/serverName
  echo -n "argocd-repo-server" > /tekton/results/repoServerName
  echo -n "argocd-application-controller" > /tekton/results/applicationControllerName
  echo -n "argocd-redis" > /tekton/results/redisName

  echo "Task results written to /tekton/results/"
fi
