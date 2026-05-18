#!/usr/bin/env bash
set -euo pipefail

# Run ArgoCD E2E tests inside e2e-test-runner pod in test cluster
# This script:
# 1. Prepares or finds pre-built test binaries (runs in Konflux)
# 2. Deploys e2e-test-runner pod (in test cluster)
# 3. Copies test assets to pod
# 4. Executes tests inside pod where they have access to git-server and ArgoCD
#
# Expected env vars (from deploy-argocd task results):
# - ARGOCD_NAMESPACE: Namespace where ArgoCD is deployed
# - ARGOCD_SERVER: ArgoCD server external Route hostname (for external access, not used by tests in pod)
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

ROOT_DIR=$(mktemp -d)
TEST_REPO_URL="${TEST_REPO_URL:-https://github.com/argoproj/argo-cd.git}"
BRANCH="${BRANCH:-v2.14.1}"

SKIP_FILE=/usr/local/config/skip-argocd.txt
if [[ -f "$SKIP_FILE" ]]; then
  ARGOCD_E2E_SKIP=$(grep -v '^\s*#' "$SKIP_FILE" | grep -v '^\s*$' | paste -sd '|')
fi
ARGOCD_E2E_SKIP="${ARGOCD_E2E_SKIP:-TestCreateAndUseAccount|TestCanIGetLogs|TestAccountSessionToken}"

ARGO_CD_DIR="${ROOT_DIR}/argo-cd"
export HOME="$ROOT_DIR"
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_TERMINAL_PROMPT=0
export GODEBUG="tarinsecurepath=0,zipinsecurepath=0"
export GOTOOLCHAIN=auto

# Cleanup on exit
cleanup_resources() {
  local exit_code=$?
  echo "Cleaning up..."

  # Clean up test namespaces
  for ns in argocd-e2e-external argocd-e2e-external-2; do
    if oc get ns "$ns" >/dev/null 2>&1; then
      oc get applications -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        xargs -n1 -I{} oc patch application {} -n "$ns" --type merge \
          -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    fi
  done
  oc delete ns -l e2e.argoproj.io=true --ignore-not-found --wait=false 2>/dev/null || true
  oc delete project argocd-e2e-external argocd-e2e-external-2 \
    --ignore-not-found --wait=false 2>/dev/null || true

  # Clean up test runner pod
  oc delete pod e2e-test-runner -n "${ARGOCD_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

  # Clean up git-server
  oc delete pod git-server -n "${ARGOCD_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
  oc delete service git-server -n "${ARGOCD_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

  exit $exit_code
}
trap cleanup_resources EXIT INT TERM

# --- Step 1: Prepare test binaries (runs in Konflux) ---

git config --global user.name "Tekton Pipeline"
git config --global user.email "tekton@example.com"
git config --global --add safe.directory "*"

echo "Checking for pre-compiled test suites..."
if [ -d /testsuites ]; then
  echo "  /testsuites directory exists"
  ls -la /testsuites/ 2>&1 | head -10
  if [ -d /testsuites/argocd ]; then
    echo "  ArgoCD test suites:"
    ls -la /testsuites/argocd/ 2>&1
  fi
else
  echo "  WARNING: /testsuites directory not found - will compile from source"
fi

# Detect test runner architecture
TARGET_ARCH=$(uname -m)
case "${TARGET_ARCH}" in
  x86_64) TARGET_ARCH="amd64" ;;
  aarch64) TARGET_ARCH="arm64" ;;
esac
echo "Test runner architecture: ${TARGET_ARCH}"

TAG="${BRANCH}"
if [[ "${BRANCH}" =~ ^v ]]; then
  TAG="${BRANCH%%+*}"
fi

IMAGE_TAG="${TAG}"
if [[ "${IMAGE_TAG}" == "master" || "${IMAGE_TAG}" == "main" ]]; then
  IMAGE_TAG="latest"
fi

# Check for pre-built ArgoCD E2E tests in test image
PREBUILT_BASE="/testsuites/argocd"
PREBUILT_DIR=""

echo "Checking for pre-built tests (TAG=${TAG}, TARGET_ARCH=${TARGET_ARCH})"

if [[ "${TAG}" =~ ^v2\.14 ]]; then
  PREBUILT_DIR="${PREBUILT_BASE}/v2.14"
  echo "  Looking for pre-built v2.14 tests at: ${PREBUILT_DIR}"
fi

# Verify pre-built binaries exist and match target architecture
if [[ -n "${PREBUILT_DIR}" ]]; then
  echo "  Checking if directory exists: ${PREBUILT_DIR}"
  ls -la "${PREBUILT_DIR}" 2>&1 || echo "  Directory not found"

  if [[ -f "${PREBUILT_DIR}/e2e.test" && -f "${PREBUILT_DIR}/dist/argocd" ]]; then
    echo "  Found pre-built binaries, checking architecture..."
    BINARY_ARCH=$(file "${PREBUILT_DIR}/e2e.test" | grep -oP '(x86-64|aarch64|ARM aarch64)' | head -1)
    echo "  Binary arch: ${BINARY_ARCH}, Target arch: ${TARGET_ARCH}"

    if [[ ("${BINARY_ARCH}" == "x86-64" && "${TARGET_ARCH}" == "amd64") || \
          (("${BINARY_ARCH}" == "aarch64" || "${BINARY_ARCH}" == "ARM aarch64") && "${TARGET_ARCH}" == "arm64") ]]; then
      echo "Using pre-built artifacts from ${PREBUILT_DIR} (${TARGET_ARCH})"
      mkdir -p "${ARGO_CD_DIR}"
      cp -a "${PREBUILT_DIR}"/* "${ARGO_CD_DIR}/"
      cd "${ARGO_CD_DIR}" || exit 1
    else
      echo "Pre-built binary architecture (${BINARY_ARCH:-unknown}) doesn't match target (${TARGET_ARCH})"
      echo "Will compile from source"
    fi
  else
    echo "  Pre-built binaries not found in ${PREBUILT_DIR}"
  fi
else
  echo "  No pre-built directory for tag ${TAG}"
fi

# If we haven't copied pre-built artifacts, clone and compile
if [[ ! -d "${ARGO_CD_DIR}" || ! -f "${ARGO_CD_DIR}/e2e.test" ]]; then
  echo "Cloning ArgoCD repository..."
  git clone --branch "${BRANCH}" --depth 1 "${TEST_REPO_URL}" "${ARGO_CD_DIR}"
  cd "${ARGO_CD_DIR}" || exit 1

  CLIENT_VERSION=$(cat VERSION 2>/dev/null || echo "unknown")
  echo "ArgoCD version: ${CLIENT_VERSION}"

  echo "Compiling E2E test binary..."
  echo "  This may take 5-7 minutes..."

  # Compile with architecture-specific target
  GOOS=linux GOARCH="${TARGET_ARCH}" go test -c \
    -ldflags "-X github.com/argoproj/argo-cd/v3/common.version=${CLIENT_VERSION}" \
    -o e2e.test ./test/e2e

  echo "E2E test binary compiled successfully"
  ls -lh e2e.test
fi

# Verify test artifacts are ready
if [[ ! -f "${ARGO_CD_DIR}/e2e.test" ]]; then
  echo "ERROR: e2e.test binary not found"
  exit 1
fi

if [[ ! -f "${ARGO_CD_DIR}/dist/argocd" ]]; then
  echo "ERROR: argocd CLI not found"
  exit 1
fi

if [[ ! -d "${ARGO_CD_DIR}/test/e2e/testdata" ]]; then
  echo "ERROR: testdata directory not found"
  exit 1
fi

echo "Test artifacts ready:"
ls -lh "${ARGO_CD_DIR}/e2e.test"
ls -lh "${ARGO_CD_DIR}/dist/argocd"
echo "Testdata fixtures: $(ls -1 "${ARGO_CD_DIR}/test/e2e/testdata" | wc -l) directories"

# Export for use by other scripts
export ARGO_CD_DIR

# --- Step 2: Deploy test infrastructure in test cluster ---

echo ""
echo "=========================================="
echo "Deploying Test Infrastructure"
echo "=========================================="

# Create test namespaces
echo "Creating test namespaces..."
oc create namespace argocd-e2e --dry-run=client -o yaml | oc apply -f -
oc create namespace argocd-e2e-external --dry-run=client -o yaml | oc apply -f -
oc label namespace argocd-e2e-external e2e.argoproj.io=true --overwrite 2>/dev/null || true
oc create namespace argocd-e2e-external-2 --dry-run=client -o yaml | oc apply -f -
oc label namespace argocd-e2e-external-2 e2e.argoproj.io=true --overwrite 2>/dev/null || true

# Grant test namespace privileges
oc -n argocd-e2e adm policy add-scc-to-user privileged -z default 2>/dev/null || true
oc adm policy add-cluster-role-to-user cluster-admin -z default -n argocd-e2e 2>/dev/null || true

# Deploy git-server
echo "Deploying git-server in test cluster..."
cat <<EOF | oc apply -n argocd-e2e -f -
apiVersion: v1
kind: Pod
metadata:
  name: git-server
  labels:
    app: git-server
spec:
  serviceAccountName: default
  containers:
  - name: git-server
    image: bitnami/git:latest
    command: ["/bin/sh", "-c"]
    args:
      - |
        mkdir -p /git/testdata.git && cd /git/testdata.git && \\
        git init --bare && touch git-daemon-export-ok && \\
        git daemon --base-path=/git --export-all --enable=receive-pack \\
          --port=9418 --verbose
    ports:
      - containerPort: 9418
    volumeMounts:
      - name: git-volume
        mountPath: /git
    securityContext:
      runAsUser: 0
  volumes:
    - name: git-volume
      emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: git-server
spec:
  selector:
    app: git-server
  ports:
    - port: 9418
      targetPort: 9418
EOF

echo "Waiting for git-server to be ready..."
oc wait --for=condition=Ready pod/git-server -n argocd-e2e --timeout=120s

# Deploy e2e-test-runner pod
/usr/local/bin/deploy-test-runner-pod.sh

# --- Step 3: Copy test assets to pod ---

echo ""
echo "=========================================="
echo "Copying Test Assets to Pod"
echo "=========================================="

/usr/local/bin/copy-test-assets-to-pod.sh

# --- Step 4: Run tests inside pod ---

echo ""
echo "=========================================="
echo "Running ArgoCD E2E Tests in Pod"
echo "=========================================="

# Generate test execution script for the pod
cat > /tmp/run_test_remote.sh <<'TEST_SCRIPT'
#!/bin/bash
set -euo pipefail

echo "=========================================="
echo "ArgoCD E2E Test Execution (Inside Pod)"
echo "=========================================="
echo "Pod: $(hostname)"
echo "Namespace: argocd-e2e"
echo ""

# Set environment variables for E2E tests
export ARGOCD_E2E_REMOTE=true
export ARGOCD_SERVER="argocd-server.argocd-e2e.svc.cluster.local"
export ARGOCD_SERVER_INSECURE=true
export ARGOCD_E2E_ADMIN_USERNAME=admin
export ARGOCD_E2E_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD}"

# Namespaces
export ARGOCD_E2E_NAMESPACE=argocd-e2e
export ARGOCD_E2E_APP_NAMESPACE=argocd-e2e-external
export ARGOCD_APPLICATION_NAMESPACES="argocd-e2e-external,argocd-e2e-external-2"

# Component names
export ARGOCD_E2E_SERVER_NAME="${ARGOCD_SERVER_NAME}"
export ARGOCD_E2E_REDIS_NAME="${ARGOCD_REDIS_NAME}"
export ARGOCD_E2E_REPO_SERVER_NAME="${ARGOCD_REPO_SERVER_NAME}"
export ARGOCD_E2E_APPLICATION_CONTROLLER_NAME="${ARGOCD_APPLICATION_CONTROLLER_NAME}"

# Git service (accessible via Service DNS from inside pod)
export ARGOCD_E2E_GIT_SERVICE="git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git"
export ARGOCD_E2E_REPO_DEFAULT="git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git"

# Working directory
export ARGOCD_E2E_DIR=/tmp/argo-e2e

# CLI binary location
export DIST_DIR=/tmp/argo-e2e/dist

# Add kubectl to PATH
export PATH=/tmp/bin:$PATH

# Skip tests
export ARGOCD_E2E_SKIP="${ARGOCD_E2E_SKIP}"

echo "Environment variables:"
echo "  ARGOCD_E2E_REMOTE=${ARGOCD_E2E_REMOTE}"
echo "  ARGOCD_SERVER=${ARGOCD_SERVER}"
echo "  ARGOCD_E2E_NAMESPACE=${ARGOCD_E2E_NAMESPACE}"
echo "  ARGOCD_E2E_GIT_SERVICE=${ARGOCD_E2E_GIT_SERVICE}"
echo "  DIST_DIR=${DIST_DIR}"
echo "  ARGOCD_E2E_SKIP=${ARGOCD_E2E_SKIP}"
echo ""

# Verify connectivity
echo "Verifying connectivity..."
echo "  ArgoCD server: ${ARGOCD_SERVER}"
if getent hosts argocd-server.argocd-e2e.svc.cluster.local >/dev/null 2>&1; then
  echo "    ✓ DNS resolution successful"
else
  echo "    ✗ DNS resolution failed"
  exit 1
fi

echo "  Git server: git-server.argocd-e2e.svc.cluster.local"
if getent hosts git-server.argocd-e2e.svc.cluster.local >/dev/null 2>&1; then
  echo "    ✓ DNS resolution successful"
else
  echo "    ✗ DNS resolution failed"
  exit 1
fi

echo ""
echo "ArgoCD CLI version:"
${DIST_DIR}/argocd version --client 2>&1 || true

echo ""
echo "Testdata fixtures available:"
ls -1 /tmp/argo-e2e/testdata | head -20
echo "  ... ($(ls -1 /tmp/argo-e2e/testdata | wc -l) total)"

echo ""
echo "=========================================="
echo "Executing E2E Tests"
echo "=========================================="
echo ""

cd /tmp/argo-e2e
./e2e.test -test.v -test.timeout 60m

echo ""
echo "=========================================="
echo "Tests Completed"
echo "=========================================="
TEST_SCRIPT

# Inject environment variables into script
sed -i "s/\${ARGOCD_ADMIN_PASSWORD}/${ARGOCD_ADMIN_PASSWORD}/g" /tmp/run_test_remote.sh
sed -i "s/\${ARGOCD_SERVER_NAME}/${ARGOCD_SERVER_NAME}/g" /tmp/run_test_remote.sh
sed -i "s/\${ARGOCD_REDIS_NAME}/${ARGOCD_REDIS_NAME}/g" /tmp/run_test_remote.sh
sed -i "s/\${ARGOCD_REPO_SERVER_NAME}/${ARGOCD_REPO_SERVER_NAME}/g" /tmp/run_test_remote.sh
sed -i "s/\${ARGOCD_APPLICATION_CONTROLLER_NAME}/${ARGOCD_APPLICATION_CONTROLLER_NAME}/g" /tmp/run_test_remote.sh
sed -i "s/\${ARGOCD_E2E_SKIP}/${ARGOCD_E2E_SKIP}/g" /tmp/run_test_remote.sh

# Copy script to pod
echo "Copying test execution script to pod..."
oc cp /tmp/run_test_remote.sh argocd-e2e/e2e-test-runner:/tmp/run_test_remote.sh

# Execute tests in pod
echo "Executing tests inside pod..."
echo ""

oc exec -n argocd-e2e e2e-test-runner -- bash /tmp/run_test_remote.sh

TEST_EXIT_CODE=$?

echo ""
echo "=========================================="
echo "Tests completed with exit code: ${TEST_EXIT_CODE}"
echo "=========================================="

exit ${TEST_EXIT_CODE}
