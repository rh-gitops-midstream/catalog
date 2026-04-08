#!/bin/bash
set -x

# Environment variables expected:
# - TEST_REPO_URL (optional, defaults to the pre-baked repo remote)
# - BRANCH
# - TEST_DIR
# - TIMEOUT
# - PROCS
# - KUBECONFIG

RESULTS_DIR="${RESULTS_DIR:-/tmp/task-logs}"
mkdir -p "${RESULTS_DIR}"

CACHE_DIR=$(mktemp -d)
export GOCACHE="${CACHE_DIR}/go-cache"
export GOMODCACHE="${CACHE_DIR}/go-mod"
mkdir -p "$GOCACHE" "$GOMODCACHE"

oc status

# --- Ensure argocd CLI is available (some tests call `argocd login` etc.) ---
# Extract the release-candidate argocd binary from the deployed operator image.
# The Konflux task container is x86_64 while cluster nodes may be arm64 (m6g),
# so we use oc image extract with --filter-by-os to get the correct arch.
if ! command -v argocd &>/dev/null; then
  ARGOCD_IMAGE=$(oc get deployment openshift-gitops-repo-server -n openshift-gitops \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  ARGOCD_BIN_DIR=$(mktemp -d)
  ARGOCD_EXTRACTED=false

  if [[ -n "$ARGOCD_IMAGE" ]]; then
    echo "Extracting argocd CLI from ${ARGOCD_IMAGE}..."
    EXTRACT_AUTH_DIR=$(mktemp -d)
    oc get secret pull-secret -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}' | \
      base64 -d > "${EXTRACT_AUTH_DIR}/config.json" 2>/dev/null || true

    for bin_path in /usr/local/bin/argocd /usr/bin/argocd; do
      if DOCKER_CONFIG="${EXTRACT_AUTH_DIR}" oc image extract "${ARGOCD_IMAGE}" \
          --filter-by-os=linux/amd64 \
          --path "${bin_path}:${ARGOCD_BIN_DIR}/" --confirm 2>&1; then
        if [[ -f "${ARGOCD_BIN_DIR}/argocd" ]]; then
          chmod +x "${ARGOCD_BIN_DIR}/argocd"
          if "${ARGOCD_BIN_DIR}/argocd" version --client --short 2>/dev/null; then
            ARGOCD_EXTRACTED=true
            break
          else
            echo "Extracted binary not executable on this arch, trying next path..."
            file "${ARGOCD_BIN_DIR}/argocd" 2>/dev/null || true
            rm -f "${ARGOCD_BIN_DIR}/argocd"
          fi
        fi
      fi
    done
    rm -rf "${EXTRACT_AUTH_DIR}"
  else
    echo "openshift-gitops-repo-server deployment not found"
  fi

  # Fallback: download upstream release binary matching the installed operator version
  if [[ "$ARGOCD_EXTRACTED" != "true" ]]; then
    INSTALLED_CSV=$(oc get csv -n openshift-gitops-operator \
      -o jsonpath='{.items[0].spec.version}' 2>/dev/null || true)
    if [[ -n "$INSTALLED_CSV" ]]; then
      echo "Image extraction failed, downloading argocd v${INSTALLED_CSV} from GitHub releases..."
      if curl -sSL --fail -o "${ARGOCD_BIN_DIR}/argocd" \
          "https://github.com/argoproj/argo-cd/releases/download/v${INSTALLED_CSV}/argocd-linux-amd64" 2>&1; then
        chmod +x "${ARGOCD_BIN_DIR}/argocd"
        if "${ARGOCD_BIN_DIR}/argocd" version --client --short 2>/dev/null; then
          ARGOCD_EXTRACTED=true
        else
          rm -f "${ARGOCD_BIN_DIR}/argocd"
        fi
      fi
    fi
  fi

  if [[ "$ARGOCD_EXTRACTED" == "true" ]]; then
    export PATH="${ARGOCD_BIN_DIR}:${PATH}"
    echo "argocd CLI available: $(argocd version --client --short)"
  else
    echo "WARNING: argocd CLI is NOT available — tests requiring it will fail"
    rm -rf "${ARGOCD_BIN_DIR}"
  fi
fi

cd /testsuites/gitops-operator/ || exit 1
TEST_REPO_URL="${TEST_REPO_URL:-https://github.com/rh-gitops-release-qa/gitops-operator.git}"
git remote set-url origin "${TEST_REPO_URL}" 2>/dev/null || git remote add origin "${TEST_REPO_URL}"
git fetch origin
git clean -fd
git checkout -B "${BRANCH}" "origin/${BRANCH}"

# shellcheck source=/dev/null
source /usr/local/bin/go-cache.sh
go_cache_pull "operator-${BRANCH}"

GINKGO_ARGS=()
if [[ -n "${GINKGO_SKIP:-}" ]]; then
  GINKGO_ARGS+=("--skip=${GINKGO_SKIP}")
  echo "Skipping tests matching: ${GINKGO_SKIP}"
fi

if [[ -n "${GINKGO_FOCUS_FILE:-}" ]]; then
  GINKGO_ARGS+=("--focus-file=${GINKGO_FOCUS_FILE}")
  echo "Focusing on files matching: ${GINKGO_FOCUS_FILE}"
fi

# Enable parallel mode only when PROCS > 1
PARALLEL_FLAG=""
if [[ "${PROCS:-1}" -gt 1 ]]; then
  PARALLEL_FLAG="-p"
fi

TEST_EXIT=0
/testsuites/gitops-operator/bin/ginkgo -timeout "${TIMEOUT}" ${PARALLEL_FLAG} -procs="${PROCS}" --no-color -v --trace -r \
    "${GINKGO_ARGS[@]}" \
    --junit-report="${RESULTS_DIR}/junit-results.xml" \
    --json-report="${RESULTS_DIR}/test-results.json" \
    "${TEST_DIR}/." || TEST_EXIT=$?

go_cache_push "operator-${BRANCH}"

exit $TEST_EXIT
