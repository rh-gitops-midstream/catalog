#!/usr/bin/env bash
set -euo pipefail

# Full end-to-end ArgoCD E2E test execution
# This script orchestrates the complete test flow:
# 1. Deploy ArgoCD standalone
# 2. Deploy test infrastructure (git-server, test-runner pod)
# 3. Clone, compile, and run tests inside the pod
#
# Compilation happens inside the test-runner pod (not locally), so only
# small scripts (~10KB) are copied over the network. Go build caching
# via Quay (go-cache.sh) speeds up repeat compilations.
#
# Can be run:
# - Locally for fast iteration
# - In Konflux pipeline
#
# Expected env vars:
# - ARGOCD_SERVER_IMAGE: ArgoCD server image to test
# - ARGOCD_VERSION: ArgoCD version (default: v2.14.1)
# - NAMESPACE: Target namespace (default: argocd-e2e)
# - TEST_REPO_URL: ArgoCD git repo (default: https://github.com/argoproj/argo-cd.git)
# - BRANCH: Test branch (default: v2.14.1)
# - KUBECONFIG: Path to kubeconfig

# Configuration
ARGOCD_SERVER_IMAGE="${ARGOCD_SERVER_IMAGE:?ARGOCD_SERVER_IMAGE must be set}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.14.1}"
NAMESPACE="${NAMESPACE:-argocd-e2e}"
TEST_REPO_URL="${TEST_REPO_URL:-https://github.com/argoproj/argo-cd.git}"
BRANCH="${BRANCH:-v2.14.1}"
TEST_RUN_FILTER="${TEST_RUN_FILTER:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RESULTS_DIR="${RESULTS_DIR:-/tmp/task-logs}"
mkdir -p "${RESULTS_DIR}"

TAG="${BRANCH}"
if [[ "${BRANCH}" =~ ^v ]]; then
  TAG="${BRANCH%%+*}"
fi

# Cleanup on exit
if [[ -f /usr/local/bin/lib/argocd-e2e-cleanup.sh ]]; then
  source /usr/local/bin/lib/argocd-e2e-cleanup.sh
else
  source "${SCRIPT_DIR}/lib/argocd-e2e-cleanup.sh"
fi
cleanup_resources() {
  local exit_code=$?
  cleanup_argocd_e2e "${NAMESPACE}"
  exit "$exit_code"
}
trap cleanup_resources EXIT INT TERM

# --- Step 1: Deploy ArgoCD ---

echo ""
echo "=========================================="
echo "Step 1: Deploy ArgoCD Standalone"
echo "=========================================="
echo ""

export ARGOCD_SERVER_IMAGE
export ARGOCD_VERSION
export NAMESPACE
export KUBECONFIG

if [ -f "/usr/local/bin/deploy-argocd-standalone.sh" ]; then
  /usr/local/bin/deploy-argocd-standalone.sh
else
  "${SCRIPT_DIR}/deploy-argocd-standalone.sh"
fi

# Extract results
if [ -f /tekton/results/namespace ]; then
  ARGOCD_NAMESPACE=$(cat /tekton/results/namespace)
  ARGOCD_SERVER=$(cat /tekton/results/server)
  ARGOCD_ADMIN_PASSWORD=$(cat /tekton/results/adminPassword)
  ARGOCD_SERVER_NAME=$(cat /tekton/results/serverName)
  ARGOCD_REPO_SERVER_NAME=$(cat /tekton/results/repoServerName)
  ARGOCD_APPLICATION_CONTROLLER_NAME=$(cat /tekton/results/applicationControllerName)
  ARGOCD_REDIS_NAME=$(cat /tekton/results/redisName)
else
  ARGOCD_NAMESPACE="${NAMESPACE}"
  ARGOCD_SERVER=$(oc get route argocd-server -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "argocd-server.${NAMESPACE}.svc.cluster.local")
  ARGOCD_ADMIN_PASSWORD=$(oc get secret argocd-initial-admin-secret -n "${NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "password")
  ARGOCD_SERVER_NAME="argocd-server"
  ARGOCD_REPO_SERVER_NAME="argocd-repo-server"
  ARGOCD_APPLICATION_CONTROLLER_NAME="argocd-application-controller"
  ARGOCD_REDIS_NAME="argocd-redis"
fi

export ARGOCD_NAMESPACE
export ARGOCD_SERVER
export ARGOCD_ADMIN_PASSWORD
export ARGOCD_SERVER_NAME
export ARGOCD_REPO_SERVER_NAME
export ARGOCD_APPLICATION_CONTROLLER_NAME
export ARGOCD_REDIS_NAME

echo ""
echo "ArgoCD deployed:"
echo "  Namespace: ${ARGOCD_NAMESPACE}"
echo "  Server: ${ARGOCD_SERVER}"
echo "  Admin password: ${ARGOCD_ADMIN_PASSWORD:0:8}..."

# --- Step 2: Deploy Test Infrastructure ---

echo ""
echo "=========================================="
echo "Step 2: Deploy Test Infrastructure"
echo "=========================================="
echo ""

# Create test namespaces
# External namespaces must NOT have the e2e.argoproj.io=true label — upstream
# EnsureCleanState() deletes any namespace with that label, and external
# namespaces are expected to persist throughout the test suite.
echo "Creating test namespaces..."
oc create namespace argocd-e2e --dry-run=client -o yaml | oc apply -f - 2>/dev/null || true
oc create namespace argocd-e2e-external --dry-run=client -o yaml | oc apply -f -
oc create namespace argocd-e2e-external-2 --dry-run=client -o yaml | oc apply -f -

# Grant privileges
oc -n argocd-e2e adm policy add-scc-to-user privileged -z default 2>/dev/null || true
oc adm policy add-cluster-role-to-user cluster-admin -z default -n argocd-e2e 2>/dev/null || true

# Configure ArgoCD to manage Applications in external namespaces.
# Controllers get namespace config from env vars populated via valueFrom
# referencing argocd-cmd-params-cm. Patch the configmap, then restart.
EXTERNAL_NS="argocd-e2e-external,argocd-e2e-external-2"
echo "Configuring ArgoCD for external namespaces: ${EXTERNAL_NS}"
oc patch configmap argocd-cmd-params-cm -n "${ARGOCD_NAMESPACE}" --type merge -p "{
  \"data\": {
    \"application.namespaces\": \"${EXTERNAL_NS}\",
    \"applicationsetcontroller.namespaces\": \"${EXTERNAL_NS}\",
    \"applicationsetcontroller.enable.scm.providers\": \"false\"
  }
}"

# Grant ArgoCD service accounts cluster-admin so they can manage resources
# in external namespaces (matches downstream CI's appset_cluster_role_bindings.yaml)
echo "Creating RBAC for ArgoCD in external namespaces..."
for sa in argocd-application-controller argocd-applicationset-controller argocd-server; do
  oc adm policy add-cluster-role-to-user cluster-admin \
    -z "${sa}" -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true
done

# Restart controllers to pick up configmap changes (env vars from valueFrom
# are only read at pod startup)
oc rollout restart deployment/argocd-server -n "${ARGOCD_NAMESPACE}"
oc rollout restart statefulset/argocd-application-controller -n "${ARGOCD_NAMESPACE}"
oc rollout restart deployment/argocd-applicationset-controller -n "${ARGOCD_NAMESPACE}"
oc rollout restart deployment/argocd-notifications-controller -n "${ARGOCD_NAMESPACE}"
oc rollout status deployment/argocd-server -n "${ARGOCD_NAMESPACE}" --timeout=5m
oc rollout status statefulset/argocd-application-controller -n "${ARGOCD_NAMESPACE}" --timeout=5m
oc rollout status deployment/argocd-applicationset-controller -n "${ARGOCD_NAMESPACE}" --timeout=5m
oc rollout status deployment/argocd-notifications-controller -n "${ARGOCD_NAMESPACE}" --timeout=5m

# Deploy argocd-e2e-server (git over HTTP/HTTPS/SSH + Helm repos)
if [ -f "/usr/local/bin/deploy-e2e-server.sh" ]; then
  /usr/local/bin/deploy-e2e-server.sh
else
  "${SCRIPT_DIR}/deploy-e2e-server.sh"
fi

# Deploy test-runner pod (Go-capable image)
if [ -f "/usr/local/bin/deploy-test-runner-pod.sh" ]; then
  /usr/local/bin/deploy-test-runner-pod.sh
else
  "${SCRIPT_DIR}/deploy-test-runner-pod.sh"
fi

# --- Step 2b: Extract argocd CLI from release-candidate image ---

echo ""
echo "=========================================="
echo "Extracting ArgoCD CLI from Release Candidate"
echo "=========================================="

ARGOCD_SERVER_POD=$(oc get pods -n "${ARGOCD_NAMESPACE}" \
  -l app.kubernetes.io/name=argocd-server \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

EXTRACTED_RC=false
if [[ -n "${ARGOCD_SERVER_POD}" ]]; then
  echo "Copying argocd CLI from pod ${ARGOCD_SERVER_POD}..."
  oc exec -n "${ARGOCD_NAMESPACE}" e2e-test-runner -- mkdir -p /tmp/rc-argocd

  TEMP_ARGOCD=$(mktemp)
  for bin_path in /usr/local/bin/argocd /usr/bin/argocd; do
    if oc cp "${ARGOCD_NAMESPACE}/${ARGOCD_SERVER_POD}:${bin_path}" "${TEMP_ARGOCD}" \
        -c argocd-server 2>&1; then
      if [[ -s "${TEMP_ARGOCD}" ]]; then
        oc cp "${TEMP_ARGOCD}" \
          "${ARGOCD_NAMESPACE}/e2e-test-runner:/tmp/rc-argocd/argocd"
        oc exec -n "${ARGOCD_NAMESPACE}" e2e-test-runner -- \
          chmod +x /tmp/rc-argocd/argocd
        if oc exec -n "${ARGOCD_NAMESPACE}" e2e-test-runner -- \
            /tmp/rc-argocd/argocd version --client --short 2>/dev/null; then
          EXTRACTED_RC=true
          echo "Release-candidate argocd CLI extracted successfully"
          break
        fi
      fi
    fi
  done
  rm -f "${TEMP_ARGOCD}"

  if [[ "${EXTRACTED_RC}" != "true" ]]; then
    echo "WARNING: Could not extract argocd CLI from release-candidate image"
    echo "  Tests will fall back to source-compiled argocd CLI"
  fi
else
  echo "WARNING: argocd-server pod not found in ${ARGOCD_NAMESPACE}"
  echo "  Tests will fall back to source-compiled argocd CLI"
fi

# --- Step 3: Copy Helper Scripts to Pod ---

echo ""
echo "=========================================="
echo "Step 3: Copy Helper Scripts to Pod"
echo "=========================================="
echo ""

# Detect script locations (container vs local)
if [[ -f /usr/local/bin/go-cache.sh ]]; then
  GO_CACHE_SCRIPT=/usr/local/bin/go-cache.sh
  ORAS_HELPERS_SCRIPT=/usr/local/bin/lib/oras-helpers.sh
else
  GO_CACHE_SCRIPT="${SCRIPT_DIR}/go-cache.sh"
  ORAS_HELPERS_SCRIPT="${SCRIPT_DIR}/lib/oras-helpers.sh"
fi

# Detect skip file
if [ -f "/usr/local/config/skip-argocd.txt" ]; then
  SKIP_FILE=/usr/local/config/skip-argocd.txt
else
  SKIP_FILE="${SCRIPT_DIR}/../config/skip-argocd.txt"
fi

# Build skip pattern
SKIP_FROM_FILE=""
if [[ -f "$SKIP_FILE" ]]; then
  SKIP_FROM_FILE=$(grep -v '^\s*#' "$SKIP_FILE" | grep -v '^\s*$' | paste -sd '|')
fi
SKIP_FROM_FILE="${SKIP_FROM_FILE:-TestCreateAndUseAccount|TestCanIGetLogs|TestAccountSessionToken}"

if [[ -n "${ARGOCD_E2E_SKIP:-}" && -n "${SKIP_FROM_FILE}" ]]; then
  ARGOCD_E2E_SKIP="${SKIP_FROM_FILE}|${ARGOCD_E2E_SKIP}"
else
  ARGOCD_E2E_SKIP="${SKIP_FROM_FILE}"
fi

# Copy go-cache scripts to pod (small files, ~5KB total)
oc exec -n "${NAMESPACE}" e2e-test-runner -- mkdir -p /opt/e2e-test/lib
if [[ -f "${GO_CACHE_SCRIPT}" && -f "${ORAS_HELPERS_SCRIPT}" ]]; then
  echo "Copying go-cache scripts to pod..."
  oc cp "${GO_CACHE_SCRIPT}" "${NAMESPACE}/e2e-test-runner:/opt/e2e-test/go-cache.sh"
  oc cp "${ORAS_HELPERS_SCRIPT}" "${NAMESPACE}/e2e-test-runner:/opt/e2e-test/lib/oras-helpers.sh"
else
  echo "Go-cache scripts not found locally, skipping (compilation will run without cache)"
fi

# Copy Quay credentials if available (for go-cache push/pull)
if [[ -f /quay-credentials/.dockerconfigjson ]]; then
  echo "Copying Quay credentials to pod..."
  oc exec -n "${NAMESPACE}" e2e-test-runner -- mkdir -p /opt/e2e-test/quay-credentials
  oc cp /quay-credentials/.dockerconfigjson "${NAMESPACE}/e2e-test-runner:/opt/e2e-test/quay-credentials/.dockerconfigjson"
fi

echo "Helper scripts copied"

# --- Step 4: Build and Run Tests in Pod ---

echo ""
echo "=========================================="
echo "Step 4: Build and Run Tests in Pod"
echo "=========================================="
echo ""

# Copy inner test script to pod and execute with env vars forwarded
if [[ -f /usr/local/bin/run-argocd-e2e-in-pod-inner.sh ]]; then
  INNER_SCRIPT=/usr/local/bin/run-argocd-e2e-in-pod-inner.sh
else
  INNER_SCRIPT="${SCRIPT_DIR}/run-argocd-e2e-in-pod-inner.sh"
fi

oc cp "${INNER_SCRIPT}" "${NAMESPACE}/e2e-test-runner:/tmp/run_test.sh"

echo "Executing tests inside pod..."
oc exec -n "${NAMESPACE}" e2e-test-runner -- \
  env \
    TEST_REPO_URL="${TEST_REPO_URL}" \
    BRANCH="${BRANCH}" \
    TAG="${TAG}" \
    ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE}" \
    ARGOCD_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD}" \
    ARGOCD_SERVER_NAME="${ARGOCD_SERVER_NAME}" \
    ARGOCD_REDIS_NAME="${ARGOCD_REDIS_NAME}" \
    ARGOCD_REPO_SERVER_NAME="${ARGOCD_REPO_SERVER_NAME}" \
    ARGOCD_APPLICATION_CONTROLLER_NAME="${ARGOCD_APPLICATION_CONTROLLER_NAME}" \
    ARGOCD_E2E_SKIP="${ARGOCD_E2E_SKIP}" \
    TEST_RUN_FILTER="${TEST_RUN_FILTER}" \
    USE_RC_ARGOCD_CLI="${EXTRACTED_RC}" \
  bash /tmp/run_test.sh

TEST_EXIT_CODE=$?

echo ""
echo "=========================================="
echo "Tests completed with exit code: ${TEST_EXIT_CODE}"
echo "=========================================="

exit ${TEST_EXIT_CODE}
