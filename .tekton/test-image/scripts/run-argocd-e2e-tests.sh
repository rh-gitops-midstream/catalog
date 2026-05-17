#!/usr/bin/env bash
set -u -o pipefail

# Upstream ArgoCD E2E tests - expects ArgoCD already deployed
# This script sets up test infrastructure and runs E2E tests against existing ArgoCD
#
# Expected env vars (from deploy-argocd task results):
# - ARGOCD_NAMESPACE: Namespace where ArgoCD is deployed
# - ARGOCD_SERVER: ArgoCD server service DNS name
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

# shellcheck disable=SC2034 # these are used indirectly via ${!pid_var} in cleanup
LOGGER_PID=""
GIT_FWD_PID=""
TEMP_PF_PID=""
COMPILE_HEARTBEAT_PID=""

cleanup_resources() {
  local exit_code=$?
  echo "Cleaning up..."
  for pid_var in LOGGER_PID GIT_FWD_PID TEMP_PF_PID COMPILE_HEARTBEAT_PID; do
    local pid=${!pid_var}
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  done

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

  exit $exit_code
}
trap cleanup_resources EXIT INT TERM

# --- Clone and compile test suite ---

git config --global user.name "Tekton Pipeline"
git config --global user.email "tekton@example.com"
git config --global --add safe.directory "*"

# Debug: Check if pre-compiled test suites exist in image
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

# Detect test runner architecture (where this pod/container is running)
# Note: Tests execute in the Konflux pod, not on the target cluster nodes
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
# Match by version prefix (v2.14.1 → v2.14)
# Note: master is not pre-compiled (requires Go 1.26+)
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
    # Check if the binary architecture matches target cluster architecture
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
if [[ ! -d "${ARGO_CD_DIR}" ]]; then
  echo "Pre-built artifacts not available (want ${TAG}/${TARGET_ARCH})"
  echo "Cloning argo-cd from ${TEST_REPO_URL} @ ${BRANCH}"

  git clone --depth 1 "${TEST_REPO_URL}" "${ARGO_CD_DIR}" 2>&1
  cd "${ARGO_CD_DIR}" || exit 1

  if [[ "${BRANCH}" =~ ^v ]]; then
    git fetch --depth 1 origin "tags/$TAG" 2>&1
    git checkout FETCH_HEAD 2>&1
  fi

  mkdir -p "${ROOT_DIR}/go-cache" "${ROOT_DIR}/go-mod"
  export GOCACHE="${ROOT_DIR}/go-cache"
  export GOMODCACHE="${ROOT_DIR}/go-mod"
  export GOARCH="${TARGET_ARCH}"
  export GOOS="linux"

  # Seed from image-baked caches if available
  if [[ -d /usr/local/go-cache/build ]]; then
    cp -a /usr/local/go-cache/build/* "${GOCACHE}/" 2>/dev/null || true
  fi
  if [[ -d /usr/local/go-cache/mod ]]; then
    cp -a /usr/local/go-cache/mod/* "${GOMODCACHE}/" 2>/dev/null || true
  fi

  # shellcheck source=/dev/null
  source /usr/local/bin/go-cache.sh
  go_cache_pull "argocd-${TAG}"

  go mod download

  CLIENT_VERSION=$(cat VERSION 2>/dev/null || echo "${TAG}")
  CLIENT_VERSION="${CLIENT_VERSION#v}"

  echo "Compiling E2E test binary..."
  ( while true; do echo "still compiling..."; sleep 60; done ) &
  COMPILE_HEARTBEAT_PID=$!

  if ! go test -c -ldflags "-X github.com/argoproj/argo-cd/v3/common.version=${CLIENT_VERSION}" \
      -o e2e.test ./test/e2e 2>&1 | tee "${RESULTS_DIR}/compile.log"; then
    kill "$COMPILE_HEARTBEAT_PID" 2>/dev/null || true
    echo "ERROR: test compilation failed"
    exit 1
  fi
  kill "$COMPILE_HEARTBEAT_PID" 2>/dev/null || true

  go build -ldflags "-X github.com/argoproj/argo-cd/v3/common.version=${CLIENT_VERSION}" \
    -o "${ARGO_CD_DIR}/dist/argocd" ./cmd 2>&1

  go_cache_push "argocd-${TAG}"
fi

# --- Setup test infrastructure ---

echo "Setting up test infrastructure..."
echo "ArgoCD already deployed in namespace: ${ARGOCD_NAMESPACE}"
echo "ArgoCD server: ${ARGOCD_SERVER}"

# Create test namespaces
echo "Creating test namespaces..."
# Note: argocd-e2e already created by deploy-argocd task, just ensure it exists
oc create namespace argocd-e2e --dry-run=client -o yaml | oc apply -f -

# Only label the external namespaces for cleanup (not argocd-e2e where ArgoCD runs)
oc create namespace argocd-e2e-external --dry-run=client -o yaml | oc apply -f -
oc label namespace argocd-e2e-external e2e.argoproj.io=true --overwrite 2>/dev/null || true

oc create namespace argocd-e2e-external-2 --dry-run=client -o yaml | oc apply -f -
oc label namespace argocd-e2e-external-2 e2e.argoproj.io=true --overwrite 2>/dev/null || true

# Grant test namespace privileges
oc -n argocd-e2e adm policy add-scc-to-user privileged -z default 2>/dev/null || true
oc adm policy add-cluster-role-to-user cluster-admin -z default -n argocd-e2e 2>/dev/null || true

# Deploy git-server for test repos
echo "Deploying git-server..."
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
oc wait --for=condition=Ready pod/git-server -n argocd-e2e --timeout=120s 2>&1 || true

# --- Set ArgoCD E2E environment variables ---

echo "Configuring E2E test environment..."

# Execution mode - remote (not local goreman)
export ARGOCD_E2E_REMOTE=true

# ArgoCD connection
export ARGOCD_SERVER="${ARGOCD_SERVER}:80"
export ARGOCD_SERVER_INSECURE=true
export ARGOCD_E2E_ADMIN_USERNAME=admin
export ARGOCD_E2E_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD}"

# Namespaces
export ARGOCD_E2E_NAMESPACE=argocd-e2e
export ARGOCD_E2E_APP_NAMESPACE=argocd-e2e-external
export ARGOCD_APPLICATION_NAMESPACES="argocd-e2e-external,argocd-e2e-external-2"

# Component names (for finding deployments/pods)
export ARGOCD_E2E_SERVER_NAME="${ARGOCD_SERVER_NAME}"
export ARGOCD_E2E_REDIS_NAME="${ARGOCD_REDIS_NAME}"
export ARGOCD_E2E_REPO_SERVER_NAME="${ARGOCD_REPO_SERVER_NAME}"
export ARGOCD_E2E_APPLICATION_CONTROLLER_NAME="${ARGOCD_APPLICATION_CONTROLLER_NAME}"

# Git service
export ARGOCD_E2E_GIT_SERVICE="git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git"
export ARGOCD_E2E_REPO_DEFAULT="git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git"

# Working directory
export ARGOCD_E2E_DIR=/tmp/argo-e2e

# CLI binary location
export DIST_DIR="${ARGO_CD_DIR}/dist"

echo "Environment variables set:"
echo "  ARGOCD_E2E_REMOTE=${ARGOCD_E2E_REMOTE}"
echo "  ARGOCD_SERVER=${ARGOCD_SERVER}"
echo "  ARGOCD_E2E_NAMESPACE=${ARGOCD_E2E_NAMESPACE}"
echo "  ARGOCD_E2E_GIT_SERVICE=${ARGOCD_E2E_GIT_SERVICE}"
echo "  DIST_DIR=${DIST_DIR}"

# Verify CLI binary exists
if [[ ! -f "${DIST_DIR}/argocd" ]]; then
  echo "ERROR: ArgoCD CLI not found at ${DIST_DIR}/argocd"
  exit 1
fi

echo "ArgoCD CLI version:"
"${DIST_DIR}/argocd" version --client 2>&1 || true

# --- Run E2E tests ---

echo ""
echo "=========================================="
echo "Running ArgoCD E2E Tests"
echo "=========================================="
echo ""

cd "${ARGO_CD_DIR}/test/e2e" || exit 1

# Save KUBECONFIG for tests
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
cp "$KUBECONFIG" "${RESULTS_DIR}/kubeconfig" 2>/dev/null || true

# Run tests
./../../e2e.test -test.v -test.timeout 60m \
  ${ARGOCD_E2E_SKIP:+-test.skip "$ARGOCD_E2E_SKIP"} 2>&1 | tee "${RESULTS_DIR}/test.log"

TEST_EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "=========================================="
echo "Tests completed with exit code: ${TEST_EXIT_CODE}"
echo "=========================================="

exit "${TEST_EXIT_CODE}"
