#!/bin/bash
set -euo pipefail

# ArgoCD E2E test runner — executed inside the e2e-test-runner pod.
# All configuration is passed via environment variables from the outer script.

: "${TEST_REPO_URL:?TEST_REPO_URL must be set}"
: "${BRANCH:?BRANCH must be set}"
: "${TAG:?TAG must be set}"
: "${ARGOCD_NAMESPACE:?ARGOCD_NAMESPACE must be set}"
: "${ARGOCD_ADMIN_PASSWORD:?ARGOCD_ADMIN_PASSWORD must be set}"
: "${ARGOCD_SERVER_NAME:?ARGOCD_SERVER_NAME must be set}"
: "${ARGOCD_REDIS_NAME:?ARGOCD_REDIS_NAME must be set}"
: "${ARGOCD_REPO_SERVER_NAME:?ARGOCD_REPO_SERVER_NAME must be set}"
: "${ARGOCD_APPLICATION_CONTROLLER_NAME:?ARGOCD_APPLICATION_CONTROLLER_NAME must be set}"
: "${ARGOCD_E2E_SKIP:?ARGOCD_E2E_SKIP must be set}"
TEST_RUN_FILTER="${TEST_RUN_FILTER:-}"

echo "=========================================="
echo "ArgoCD E2E Tests (Inside Pod)"
echo "=========================================="
echo "Pod: $(hostname)"
echo ""

# --- Phase 1: Clone and Compile ---

WORKDIR=/opt/e2e-test
ARGO_CD_DIR="${WORKDIR}/argo-cd"
export HOME="${WORKDIR}"
export GOCACHE="${WORKDIR}/go-cache"
export GOMODCACHE="${WORKDIR}/go-mod"
export GODEBUG="tarinsecurepath=0,zipinsecurepath=0"
export GOTOOLCHAIN=auto
mkdir -p "${GOCACHE}" "${GOMODCACHE}"

git config --global user.name "E2E Test"
git config --global user.email "e2e@example.com"
git config --global --add safe.directory "*"

TARGET_ARCH=$(uname -m)
case "${TARGET_ARCH}" in
  x86_64) TARGET_ARCH="amd64" ;;
  aarch64) TARGET_ARCH="arm64" ;;
esac

# Check for pre-built tests (pipeline image has /testsuites/argocd/v2.14/)
if [[ "${TAG}" =~ ^v2\.14 ]] && [[ -d /testsuites/argocd/v2.14 ]]; then
  PREBUILT_DIR="/testsuites/argocd/v2.14"
  if [[ -f "${PREBUILT_DIR}/e2e.test" && -f "${PREBUILT_DIR}/dist/argocd" ]]; then
    BINARY_ARCH=$(file "${PREBUILT_DIR}/e2e.test" | grep -oP '(x86-64|aarch64|ARM aarch64)' | head -1)
    if [[ ("${BINARY_ARCH}" == "x86-64" && "${TARGET_ARCH}" == "amd64") || \
          (("${BINARY_ARCH}" == "aarch64" || "${BINARY_ARCH}" == "ARM aarch64") && "${TARGET_ARCH}" == "arm64") ]]; then
      echo "Using pre-built tests from ${PREBUILT_DIR}"
      mkdir -p "${ARGO_CD_DIR}"
      cp -a "${PREBUILT_DIR}"/* "${ARGO_CD_DIR}/"
      if [[ "${USE_RC_ARGOCD_CLI:-false}" == "true" && -f /tmp/rc-argocd/argocd ]]; then
        echo "Overriding pre-built argocd CLI with release-candidate binary"
        cp /tmp/rc-argocd/argocd "${ARGO_CD_DIR}/dist/argocd"
        chmod +x "${ARGO_CD_DIR}/dist/argocd"
      fi
    fi
  fi
fi

# Clone and compile if no pre-built tests
if [[ ! -f "${ARGO_CD_DIR}/e2e.test" ]]; then
  echo "Cloning ArgoCD ${BRANCH}..."
  git clone --branch "${BRANCH}" --depth 1 "${TEST_REPO_URL}" "${ARGO_CD_DIR}"
  cd "${ARGO_CD_DIR}"

  # Pull go-cache (best-effort)
  if [[ -f /opt/e2e-test/go-cache.sh ]]; then
    if [[ -f /opt/e2e-test/quay-credentials/.dockerconfigjson ]]; then
      mkdir -p /quay-credentials
      ln -sf /opt/e2e-test/quay-credentials/.dockerconfigjson /quay-credentials/.dockerconfigjson
    fi
    source /opt/e2e-test/go-cache.sh
    go_cache_pull "argocd-${TAG}" || true
  fi

  go mod download

  CLIENT_VERSION=$(cat VERSION 2>/dev/null || echo "${TAG}")
  CLIENT_VERSION="${CLIENT_VERSION#v}"
  MODULE_PATH=$(head -1 go.mod | awk '{print $2}')

  echo "Compiling E2E test binary (${TARGET_ARCH})..."
  ( while true; do echo "still compiling..."; sleep 60; done ) &
  HEARTBEAT_PID=$!

  GOOS=linux GOARCH="${TARGET_ARCH}" go test -c \
    -ldflags "-X ${MODULE_PATH}/common.version=${CLIENT_VERSION}" \
    -o e2e.test ./test/e2e

  if [[ "${USE_RC_ARGOCD_CLI:-false}" == "true" && -f /tmp/rc-argocd/argocd ]]; then
    echo "Using release-candidate argocd CLI from deployed image"
    mkdir -p dist
    cp /tmp/rc-argocd/argocd dist/argocd
    chmod +x dist/argocd
    echo "RC argocd version: $(dist/argocd version --client --short 2>/dev/null || echo 'unknown')"
  else
    echo "Building ArgoCD CLI from source..."
    GOOS=linux GOARCH="${TARGET_ARCH}" go build \
      -ldflags "-X ${MODULE_PATH}/common.version=${CLIENT_VERSION}" \
      -o dist/argocd ./cmd
  fi

  kill "${HEARTBEAT_PID}" 2>/dev/null || true

  # Push updated go-cache (best-effort)
  if [[ -f /opt/e2e-test/go-cache.sh ]]; then
    go_cache_push "argocd-${TAG}" || true
  fi
fi

echo "Test assets ready:"
ls -lh "${ARGO_CD_DIR}/e2e.test"
ls -lh "${ARGO_CD_DIR}/dist/argocd"

# --- Phase 2: Run Tests ---

export ARGOCD_E2E_REMOTE=true
export ARGOCD_SERVER="argocd-server.${ARGOCD_NAMESPACE}.svc.cluster.local"
export ARGOCD_E2E_ADMIN_USERNAME=admin
export ARGOCD_E2E_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD}"
export ARGOCD_E2E_NAMESPACE="${ARGOCD_NAMESPACE}"
export ARGOCD_E2E_APP_NAMESPACE=argocd-e2e-external
export ARGOCD_APPLICATION_NAMESPACES="argocd-e2e-external,argocd-e2e-external-2"
export ARGOCD_E2E_SERVER_NAME="${ARGOCD_SERVER_NAME}"
export ARGOCD_E2E_REDIS_NAME="${ARGOCD_REDIS_NAME}"
export ARGOCD_E2E_REPO_SERVER_NAME="${ARGOCD_REPO_SERVER_NAME}"
export ARGOCD_E2E_APPLICATION_CONTROLLER_NAME="${ARGOCD_APPLICATION_CONTROLLER_NAME}"
# Push URLs (unauthenticated HTTP for CI to push test fixtures)
export ARGOCD_E2E_GIT_SERVICE="http://argocd-e2e-server:9081/argo-e2e/testdata.git"
export ARGOCD_E2E_HELM_SERVICE="http://argocd-e2e-server:9081/helm-repo"
export ARGOCD_E2E_GIT_SERVICE_SUBMODULE="http://argocd-e2e-server:9081/argo-e2e/submodule.git"
export ARGOCD_E2E_GIT_SERVICE_SUBMODULE_PARENT="http://argocd-e2e-server:9081/argo-e2e/submoduleParent.git"
# Test URLs (what ArgoCD uses to fetch repos)
export ARGOCD_E2E_REPO_SSH="ssh://root@argocd-e2e-server:2222/tmp/argo-e2e/testdata.git"
export ARGOCD_E2E_REPO_SSH_SUBMODULE="ssh://root@argocd-e2e-server:2222/tmp/argo-e2e/submodule.git"
export ARGOCD_E2E_REPO_SSH_SUBMODULE_PARENT="ssh://root@argocd-e2e-server:2222/tmp/argo-e2e/submoduleParent.git"
export ARGOCD_E2E_REPO_HTTPS="https://argocd-e2e-server:9443/argo-e2e/testdata.git"
export ARGOCD_E2E_REPO_HTTPS_CLIENT_CERT="https://argocd-e2e-server:9444/argo-e2e/testdata.git"
export ARGOCD_E2E_REPO_HTTPS_SUBMODULE="https://argocd-e2e-server:9443/argo-e2e/submodule.git"
export ARGOCD_E2E_REPO_HTTPS_SUBMODULE_PARENT="https://argocd-e2e-server:9443/argo-e2e/submoduleParent.git"
export ARGOCD_E2E_REPO_HELM="https://argocd-e2e-server:9444/helm-repo"
export ARGOCD_E2E_REPO_DEFAULT="http://argocd-e2e-server:9081/argo-e2e/testdata.git"
# Skip flags
export ARGOCD_E2E_SKIP_GPG=true
export ARGOCD_E2E_SKIP_OPENSHIFT=true
export ARGOCD_E2E_SKIP_HELM=false
export ARGOCD_E2E_K3S=true
export ARGOCD_E2E_DEFAULT_TIMEOUT=30
export ARGOCD_GPG_ENABLED=true
export NO_PROXY="*"
export ARGOCD_E2E_SKIP="${ARGOCD_E2E_SKIP}"
export PATH="${ARGO_CD_DIR}/dist:/tmp/bin:${PATH}"

# Ensure kubectl is available (go-toolset image only has oc)
mkdir -p /tmp/bin
if ! command -v kubectl >/dev/null 2>&1; then
  if command -v oc >/dev/null 2>&1; then
    ln -sf "$(which oc)" /tmp/bin/kubectl
    echo "Symlinked kubectl -> $(which oc)"
  else
    echo "WARNING: neither kubectl nor oc found"
  fi
fi

echo ""
echo "Connectivity checks:"
getent hosts "argocd-server.${ARGOCD_NAMESPACE}.svc.cluster.local" || echo "  WARNING: ArgoCD DNS failed"
getent hosts "argocd-e2e-server" || echo "  WARNING: argocd-e2e-server DNS failed"

# Run from test/e2e/ (upstream convention — relative paths depend on this)
cd "${ARGO_CD_DIR}/test/e2e"

# Crash-resilient test runner: upstream fixture code contains log.Fatal() calls
# that kill the entire test binary when certain operations fail (repo add, cluster
# upsert). This loop detects crashes, identifies the offending test, adds it to
# the skip list, and re-runs the remaining tests.
MAX_CRASH_RETRIES=5
CRASH_RETRY=0
CRASH_SKIP=""
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
FINAL_EXIT=0
TEST_LOG="/tmp/e2e-test-run.log"

while true; do
  FULL_SKIP="${ARGOCD_E2E_SKIP}"
  if [[ -n "${CRASH_SKIP}" ]]; then
    FULL_SKIP="${FULL_SKIP:+${FULL_SKIP}|}${CRASH_SKIP}"
  fi

  if [[ ${CRASH_RETRY} -gt 0 ]]; then
    echo ""
    echo "=========================================="
    echo "Crash recovery retry ${CRASH_RETRY}/${MAX_CRASH_RETRIES}"
    echo "  Crashed tests skipped: ${CRASH_SKIP}"
    echo "=========================================="
    # Recreate external namespaces (crash or EnsureCleanState may have removed them)
    kubectl create namespace argocd-e2e-external --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    kubectl create namespace argocd-e2e-external-2 --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
  fi
  echo ""
  echo "Running: ${ARGO_CD_DIR}/e2e.test -test.v -test.timeout 60m"
  [[ -n "${TEST_RUN_FILTER}" ]] && echo "  Run:  ${TEST_RUN_FILTER}"
  echo "  Skip: ${FULL_SKIP}"
  echo ""

  set +e
  ${ARGO_CD_DIR}/e2e.test -test.v -test.timeout 60m \
    ${TEST_RUN_FILTER:+-test.run "${TEST_RUN_FILTER}"} \
    ${FULL_SKIP:+-test.skip "${FULL_SKIP}"} 2>&1 | tee "${TEST_LOG}"
  EXIT_CODE=${PIPESTATUS[0]}
  set -e

  RUN_PASSED=$(grep -c '^--- PASS:' "${TEST_LOG}" 2>/dev/null || true)
  RUN_FAILED=$(grep -c '^--- FAIL:' "${TEST_LOG}" 2>/dev/null || true)
  RUN_SKIPPED=$(grep -c '^--- SKIP:' "${TEST_LOG}" 2>/dev/null || true)
  TOTAL_PASSED=$((TOTAL_PASSED + RUN_PASSED))
  TOTAL_FAILED=$((TOTAL_FAILED + RUN_FAILED))
  TOTAL_SKIPPED=$((TOTAL_SKIPPED + RUN_SKIPPED))

  if [[ ${EXIT_CODE} -eq 0 ]]; then
    break
  fi

  # Check if the binary completed normally (last lines contain "FAIL" or "ok")
  if tail -5 "${TEST_LOG}" | grep -qE '^(FAIL|ok\s)'; then
    FINAL_EXIT=${EXIT_CODE}
    break
  fi

  # Binary crashed mid-suite
  CRASH_RETRY=$((CRASH_RETRY + 1))

  # Extract the top-level test that was running when the crash happened
  CRASHED_TEST=$(grep '^=== RUN ' "${TEST_LOG}" | tail -1 \
    | sed 's/=== RUN   *//' | awk '{print $1}' | cut -d/ -f1)

  if [[ -z "${CRASHED_TEST}" ]]; then
    echo "ERROR: Binary crashed but could not identify the crashing test"
    FINAL_EXIT=${EXIT_CODE}
    break
  fi

  TOTAL_FAILED=$((TOTAL_FAILED + 1))

  echo ""
  echo "=========================================="
  echo "CRASH DETECTED during: ${CRASHED_TEST}"
  echo "  Exit code: ${EXIT_CODE}"
  echo "  Tests completed before crash: $((RUN_PASSED + RUN_FAILED + RUN_SKIPPED))"
  echo "=========================================="

  if [[ ${CRASH_RETRY} -gt ${MAX_CRASH_RETRIES} ]]; then
    echo "Max crash retries (${MAX_CRASH_RETRIES}) exceeded"
    FINAL_EXIT=${EXIT_CODE}
    break
  fi

  CRASH_SKIP="${CRASH_SKIP:+${CRASH_SKIP}|}${CRASHED_TEST}"
  echo "Skipping ${CRASHED_TEST}, retrying remaining tests..."
done

echo ""
echo "=========================================="
echo "Final Results"
echo "=========================================="
echo "  Passed:  ${TOTAL_PASSED}"
echo "  Failed:  ${TOTAL_FAILED}"
echo "  Skipped: ${TOTAL_SKIPPED}"
if [[ ${CRASH_RETRY} -gt 0 ]]; then
  echo "  Crash retries: ${CRASH_RETRY}"
  echo "  Crashed tests: ${CRASH_SKIP}"
fi

if [[ ${TOTAL_FAILED} -gt 0 || ${FINAL_EXIT} -ne 0 ]]; then
  exit 1
fi
