#!/bin/bash
# Shared cleanup for ArgoCD E2E test resources.
# Source this file and call cleanup_argocd_e2e from your trap.

cleanup_argocd_e2e() {
  local namespace="${1:-${ARGOCD_NAMESPACE:-argocd-e2e}}"

  echo "Cleaning up ArgoCD E2E resources (namespace: ${namespace})..."

  for ns in argocd-e2e-external argocd-e2e-external-2; do
    if oc get ns "$ns" >/dev/null 2>&1; then
      oc get applications -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        xargs -n1 -I{} oc patch application {} -n "$ns" --type merge \
          -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    fi
  done

  if oc get ns "$namespace" >/dev/null 2>&1; then
    oc get applications -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
      xargs -n1 -I{} oc patch application {} -n "$namespace" --type merge \
        -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  fi

  oc delete ns -l e2e.argoproj.io=true --ignore-not-found --wait=false 2>/dev/null || true
  oc delete project argocd-e2e-external argocd-e2e-external-2 \
    --ignore-not-found --wait=false 2>/dev/null || true

  oc delete pod e2e-test-runner -n "$namespace" --ignore-not-found --wait=false 2>/dev/null || true
  oc delete deployment argocd-e2e-cluster -n "$namespace" --ignore-not-found --wait=false 2>/dev/null || true
  oc delete service argocd-e2e-server -n "$namespace" --ignore-not-found --wait=false 2>/dev/null || true
}
