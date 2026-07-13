#!/usr/bin/env bash
set -euo pipefail

# Run ArgoCD E2E tests inside e2e-test-runner pod in test cluster
# This script:
# 1. Deploys test infrastructure (git-server, test-runner pod)
# 2. Copies helper scripts to pod (~10KB)
# 3. Pod clones, compiles (with go-cache), and runs tests
#
# Compilation happens inside the pod, not in the Konflux task container.
# Go build caching via Quay (go-cache.sh) speeds up repeat compilations.
# Pre-built test suites at /testsuites/ are detected and used if available.
#
# Expected env vars (from deploy-argocd task results):
# - ARGOCD_NAMESPACE: Namespace where ArgoCD is deployed
# - ARGOCD_ADMIN_PASSWORD: ArgoCD admin password
# - ARGOCD_SERVER_NAME: ArgoCD server deployment name
# - ARGOCD_REPO_SERVER_NAME: ArgoCD repo-server deployment name
# - ARGOCD_APPLICATION_CONTROLLER_NAME: ArgoCD application-controller deployment name
# - ARGOCD_REDIS_NAME: ArgoCD redis deployment name
#
# Other expected env vars:
# - TEST_REPO_URL: ArgoCD git repo URL (default: https://github.com/argoproj/argo-cd.git)
# - BRANCH: ArgoCD version tag or branch (default: v2.14.1)
# - KUBECONFIG: Path to kubeconfig

RESULTS_DIR="${RESULTS_DIR:-/tmp/task-logs}"
mkdir -p "${RESULTS_DIR}"

TEST_REPO_URL="${TEST_REPO_URL:-https://github.com/argoproj/argo-cd.git}"
BRANCH="${BRANCH:-v2.14.1}"

SKIP_FILE=/usr/local/config/skip-argocd.txt
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

TAG="${BRANCH}"
if [[ "${BRANCH}" =~ ^v ]]; then
  TAG="${BRANCH%%+*}"
fi

# Cleanup on exit
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /usr/local/bin/lib/argocd-e2e-cleanup.sh ]]; then
  source /usr/local/bin/lib/argocd-e2e-cleanup.sh
else
  source "${SCRIPT_DIR}/lib/argocd-e2e-cleanup.sh"
fi
cleanup_resources() {
  local exit_code=$?
  cleanup_argocd_e2e "${ARGOCD_NAMESPACE}"
  exit "$exit_code"
}
trap cleanup_resources EXIT INT TERM

# --- Step 1: Deploy test infrastructure ---

echo ""
echo "=========================================="
echo "Deploying Test Infrastructure"
echo "=========================================="

# Create test namespaces
# External namespaces must NOT have the e2e.argoproj.io=true label — upstream
# EnsureCleanState() deletes any namespace with that label, and external
# namespaces are expected to persist throughout the test suite.
echo "Creating test namespaces..."
oc create namespace argocd-e2e --dry-run=client -o yaml | oc apply -f -
oc create namespace argocd-e2e-external --dry-run=client -o yaml | oc apply -f -
oc create namespace argocd-e2e-external-2 --dry-run=client -o yaml | oc apply -f -

# Grant test namespace privileges
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

# Restart controllers to pick up configmap changes
oc rollout restart deployment/argocd-server -n "${ARGOCD_NAMESPACE}"
oc rollout restart statefulset/argocd-application-controller -n "${ARGOCD_NAMESPACE}"
oc rollout restart deployment/argocd-applicationset-controller -n "${ARGOCD_NAMESPACE}"
oc rollout restart deployment/argocd-notifications-controller -n "${ARGOCD_NAMESPACE}"
oc rollout status deployment/argocd-server -n "${ARGOCD_NAMESPACE}" --timeout=5m
oc rollout status statefulset/argocd-application-controller -n "${ARGOCD_NAMESPACE}" --timeout=5m
oc rollout status deployment/argocd-applicationset-controller -n "${ARGOCD_NAMESPACE}" --timeout=5m
oc rollout status deployment/argocd-notifications-controller -n "${ARGOCD_NAMESPACE}" --timeout=5m

# Deploy argocd-e2e-server (git over HTTP/HTTPS/SSH + Helm repos)
echo "Deploying argocd-e2e-server..."
/usr/local/bin/deploy-e2e-server.sh

# Deploy test-runner pod (Go-capable image)
/usr/local/bin/deploy-test-runner-pod.sh

# --- Step 1b: Extract argocd CLI from release-candidate image ---

echo ""
echo "=========================================="
echo "Extracting ArgoCD CLI from Release Candidate"
echo "=========================================="

# The argocd-server pod runs the release-candidate image. Copy the argocd
# binary from it to the test-runner pod. Both pods run on the same cluster
# (same architecture), so no cross-arch issues.
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

# --- Step 2: Copy helper scripts to pod ---

echo ""
echo "=========================================="
echo "Copying Helper Scripts to Pod"
echo "=========================================="

oc exec -n "${ARGOCD_NAMESPACE}" e2e-test-runner -- mkdir -p /opt/e2e-test/lib

# Copy go-cache scripts if available (pipeline image has oras; multi-arch go-toolset does not)
if [[ -f /usr/local/bin/go-cache.sh && -f /usr/local/bin/lib/oras-helpers.sh ]]; then
  echo "Copying go-cache scripts to pod..."
  oc cp /usr/local/bin/go-cache.sh "${ARGOCD_NAMESPACE}/e2e-test-runner:/opt/e2e-test/go-cache.sh"
  oc cp /usr/local/bin/lib/oras-helpers.sh "${ARGOCD_NAMESPACE}/e2e-test-runner:/opt/e2e-test/lib/oras-helpers.sh"

  if [[ -f /quay-credentials/.dockerconfigjson ]]; then
    echo "Copying Quay credentials to pod..."
    oc exec -n "${ARGOCD_NAMESPACE}" e2e-test-runner -- mkdir -p /quay-credentials
    oc cp /quay-credentials/.dockerconfigjson "${ARGOCD_NAMESPACE}/e2e-test-runner:/quay-credentials/.dockerconfigjson"
  fi
else
  echo "Go-cache scripts not found, skipping (compilation will run without cache)"
fi

echo "Helper scripts copied"

# --- Step 3: Build and run tests inside pod ---

echo ""
echo "=========================================="
echo "Running ArgoCD E2E Tests in Pod"
echo "=========================================="

# Copy inner test script to pod and execute with env vars forwarded
oc cp /usr/local/bin/run-argocd-e2e-in-pod-inner.sh \
  "${ARGOCD_NAMESPACE}/e2e-test-runner:/tmp/run_test.sh"

echo "Executing tests inside pod..."
oc exec -n "${ARGOCD_NAMESPACE}" e2e-test-runner -- \
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
    TEST_RUN_FILTER="${TEST_RUN_FILTER:-}" \
    USE_RC_ARGOCD_CLI="${EXTRACTED_RC}" \
  bash /tmp/run_test.sh

TEST_EXIT_CODE=$?

echo ""
echo "=========================================="
echo "Tests completed with exit code: ${TEST_EXIT_CODE}"
echo "=========================================="

exit ${TEST_EXIT_CODE}
