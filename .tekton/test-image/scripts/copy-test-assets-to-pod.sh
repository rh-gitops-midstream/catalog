#!/bin/bash
set -euo pipefail

# Copy test assets to e2e-test-runner pod
# - Test binary (e2e.test)
# - ArgoCD CLI (dist/argocd)
# - Test fixtures (test/e2e/testdata/)
# - kubectl binary

NAMESPACE="${ARGOCD_NAMESPACE:-argocd-e2e}"
ARGO_CD_DIR="${ARGO_CD_DIR:-/tmp/tmp.*/argo-cd}"

# If ARGO_CD_DIR has wildcard, expand it
if [[ "${ARGO_CD_DIR}" == *"*"* ]]; then
  # shellcheck disable=SC2086,SC2116
  ARGO_CD_DIR=$(echo ${ARGO_CD_DIR})
fi

echo "Copying test assets to e2e-test-runner pod..."
echo "Source directory: ${ARGO_CD_DIR}"

# Verify source files exist
if [[ ! -f "${ARGO_CD_DIR}/e2e.test" ]]; then
  echo "ERROR: e2e.test not found at ${ARGO_CD_DIR}/e2e.test"
  ls -la "${ARGO_CD_DIR}/" || true
  exit 1
fi

if [[ ! -f "${ARGO_CD_DIR}/dist/argocd" ]]; then
  echo "ERROR: argocd CLI not found at ${ARGO_CD_DIR}/dist/argocd"
  exit 1
fi

if [[ ! -d "${ARGO_CD_DIR}/test/e2e/testdata" ]]; then
  echo "ERROR: testdata directory not found at ${ARGO_CD_DIR}/test/e2e/testdata"
  exit 1
fi

# Copy test binary
echo "  Copying e2e.test binary..."
oc cp "${ARGO_CD_DIR}/e2e.test" \
  "${NAMESPACE}/e2e-test-runner:/tmp/argo-e2e/e2e.test"

# Make it executable
oc exec -n "${NAMESPACE}" e2e-test-runner -- \
  chmod +x /tmp/argo-e2e/e2e.test

# Copy ArgoCD CLI
echo "  Copying ArgoCD CLI..."
oc exec -n "${NAMESPACE}" e2e-test-runner -- mkdir -p /tmp/argo-e2e/dist
oc cp "${ARGO_CD_DIR}/dist/argocd" \
  "${NAMESPACE}/e2e-test-runner:/tmp/argo-e2e/dist/argocd"

oc exec -n "${NAMESPACE}" e2e-test-runner -- \
  chmod +x /tmp/argo-e2e/dist/argocd

# Copy testdata directory (create tarball first for efficiency)
echo "  Copying testdata fixtures (79 directories)..."
TESTDATA_COUNT=$(ls -1 "${ARGO_CD_DIR}/test/e2e/testdata" | wc -l)
echo "    Found ${TESTDATA_COUNT} fixtures"

tar -czf /tmp/testdata.tar.gz -C "${ARGO_CD_DIR}/test/e2e" testdata
oc cp /tmp/testdata.tar.gz \
  "${NAMESPACE}/e2e-test-runner:/tmp/argo-e2e/testdata.tar.gz"

oc exec -n "${NAMESPACE}" e2e-test-runner -- \
  tar -xzf /tmp/argo-e2e/testdata.tar.gz -C /tmp/argo-e2e/

rm -f /tmp/testdata.tar.gz

# Copy kubectl (tests use kubectl to check resources)
echo "  Copying kubectl binary..."
oc cp "$(which oc)" \
  "${NAMESPACE}/e2e-test-runner:/tmp/bin/kubectl"

oc exec -n "${NAMESPACE}" e2e-test-runner -- \
  chmod +x /tmp/bin/kubectl

echo "Test assets copied successfully"
echo "Pod contents:"
oc exec -n "${NAMESPACE}" e2e-test-runner -- ls -lh /tmp/argo-e2e/
