#!/bin/bash
set -euo pipefail

# Clean up all resources from an ArgoCD E2E test run.
# Safe to run multiple times.

NAMESPACE="${NAMESPACE:-argocd-e2e}"

echo "=========================================="
echo "ArgoCD E2E Cleanup"
echo "=========================================="
echo "Namespace: ${NAMESPACE}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /usr/local/bin/lib/argocd-e2e-cleanup.sh ]]; then
  source /usr/local/bin/lib/argocd-e2e-cleanup.sh
else
  source "${SCRIPT_DIR}/lib/argocd-e2e-cleanup.sh"
fi
cleanup_argocd_e2e "${NAMESPACE}"

# Delete the main namespace (this removes ArgoCD and everything in it)
echo "Deleting namespace ${NAMESPACE}..."
oc delete namespace "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true

# Wait for namespace to be fully gone
echo "Waiting for namespace deletion..."
for _i in $(seq 1 60); do
  if ! oc get namespace "$NAMESPACE" 2>/dev/null; then
    echo "Cleanup complete"
    exit 0
  fi
  sleep 2
done

echo "WARNING: namespace ${NAMESPACE} still terminating after 2 minutes"
echo "Run 'oc get namespace ${NAMESPACE}' to check status"
