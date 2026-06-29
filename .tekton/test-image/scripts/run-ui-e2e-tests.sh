#!/usr/bin/env bash
set -u -o pipefail

# Playwright UI E2E tests for the gitops-operator.
# Runs browser-based tests that verify ArgoCD login via OpenShift SSO.
#
# Unlike the ginkgo-based test scripts, this does NOT exec into run-e2e-tests.sh
# because the test framework is Playwright (Node.js), not Go/ginkgo.
#
# Env vars expected:
#   KUBECONFIG          - path to cluster kubeconfig
#   TEST_REPO_URL       - gitops-operator repo URL
#   BRANCH              - branch/tag containing test/ui-e2e
# Optional:
#   CLUSTER_USER        - OpenShift username (default: kubeadmin)
#   CLUSTER_PASSWORD    - OpenShift password (auto-discovered if not set)
#   CONSOLE_URL         - OpenShift console URL (auto-discovered)
#   ARGOCD_URL          - ArgoCD server URL (auto-discovered)
#   IDP                 - Identity provider name (default: kube:admin)

# shellcheck source=./lib/load-skip-patterns.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/load-skip-patterns.sh"

RESULTS_DIR="${RESULTS_DIR:-/tmp/task-logs}"
mkdir -p "${RESULTS_DIR}"

ROOT_DIR=$(mktemp -d)
TEST_REPO_URL="${TEST_REPO_URL:-https://github.com/redhat-developer/gitops-operator.git}"
BRANCH="${BRANCH:-master}"

# --- Clone test repo ---

echo "Cloning ${TEST_REPO_URL} @ ${BRANCH}"
git config --global --add safe.directory "*"
git clone --depth 1 --branch "${BRANCH}" "${TEST_REPO_URL}" "${ROOT_DIR}/gitops-operator" 2>&1

UI_TEST_DIR="${ROOT_DIR}/gitops-operator/test/ui-e2e"
if [[ ! -d "$UI_TEST_DIR" ]]; then
  echo "ERROR: test/ui-e2e directory not found in ${TEST_REPO_URL} @ ${BRANCH}"
  exit 1
fi
cd "${UI_TEST_DIR}" || exit 1

# --- Install dependencies ---

echo "Installing npm dependencies..."
npm ci 2>&1

echo "Installing Playwright browser dependencies..."
if command -v dnf &>/dev/null; then
  dnf -y install \
    alsa-lib atk at-spi2-atk cups-libs libdrm mesa-libgbm \
    gtk3 nss libXcomposite libXdamage libXrandr pango \
    libxkbcommon libXScrnSaver 2>&1 || true
elif command -v apt-get &>/dev/null; then
  npx playwright install-deps chromium 2>&1 || true
fi

echo "Installing Playwright Chromium..."
npx playwright install chromium 2>&1

# --- Discover cluster URLs ---

if [[ -z "${CONSOLE_URL:-}" ]]; then
  CONSOLE_HOST=$(oc get route console -n openshift-console \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -n "$CONSOLE_HOST" ]]; then
    CONSOLE_URL="https://${CONSOLE_HOST}"
  fi
fi

if [[ -z "${ARGOCD_URL:-}" ]]; then
  ARGOCD_HOST=$(oc get route -n openshift-gitops openshift-gitops-server \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -n "$ARGOCD_HOST" ]]; then
    ARGOCD_URL="https://${ARGOCD_HOST}"
  fi
fi

if [[ -z "${ARGOCD_URL:-}" ]]; then
  echo "ERROR: Could not discover ArgoCD URL. Set ARGOCD_URL or check the route."
  oc get routes -n openshift-gitops 2>/dev/null || true
  exit 1
fi

if [[ -z "${CONSOLE_URL:-}" ]]; then
  echo "WARNING: Could not discover OpenShift Console URL. SSO login tests may fail."
fi

# --- Get cluster credentials ---

CLUSTER_USER="${CLUSTER_USER:-kubeadmin}"
if [[ -z "${CLUSTER_PASSWORD:-}" ]]; then
  PASS_FILE=$(find /credentials -name "*password" -type f 2>/dev/null | head -1)
  if [[ -n "$PASS_FILE" ]]; then
    CLUSTER_PASSWORD=$(cat "$PASS_FILE")
    echo "Discovered cluster password from ${PASS_FILE}"
  fi
fi

if [[ -z "${CLUSTER_PASSWORD:-}" ]]; then
  CLUSTER_PASSWORD=$(oc get secret kubeadmin -n kube-system \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi

if [[ -z "${CLUSTER_PASSWORD:-}" ]]; then
  echo "ERROR: CLUSTER_PASSWORD not set and could not be auto-discovered."
  echo "Set CLUSTER_PASSWORD env var, ensure /credentials contains a password file,"
  echo "or ensure kubeadmin secret exists in kube-system."
  exit 1
fi

echo "Console URL:  ${CONSOLE_URL:-unset}"
echo "ArgoCD URL:   ${ARGOCD_URL}"
echo "Cluster user: ${CLUSTER_USER}"

# --- Handle skip patterns ---

readarray -t PLAYWRIGHT_EXTRA_ARGS < <(load_playwright_skip_patterns /usr/local/config/skip-ui-e2e.txt)
if [ ${#PLAYWRIGHT_EXTRA_ARGS[@]} -gt 0 ]; then
  echo "Skipping tests matching: ${PLAYWRIGHT_EXTRA_ARGS[1]}"
fi

# --- Run Playwright tests ---

export CONSOLE_URL="${CONSOLE_URL:-}"
export ARGOCD_URL
export CLUSTER_USER
export CLUSTER_PASSWORD
if [[ -z "${IDP:-}" ]]; then
  IDP_NAME=$(oc get oauth cluster -o jsonpath='{.spec.identityProviders[0].name}' 2>/dev/null || true)
  IDP="${IDP_NAME:-kube:admin}"
fi
export IDP
export CI="konflux"
export PLAYWRIGHT_JUNIT_OUTPUT_NAME="${RESULTS_DIR}/junit-results.xml"

# Clean stale browser state
rm -f .auth/storageState.json

echo "Running UI E2E tests..."
npx playwright test \
  --project=chromium \
  --reporter=list,junit \
  "${PLAYWRIGHT_EXTRA_ARGS[@]}" \
  2>&1 | tee "${RESULTS_DIR}/ui-e2e.log"
TEST_EXIT_CODE=${PIPESTATUS[0]}

# --- Collect artifacts ---

for dir in playwright-report test-results; do
  if [[ -d "$dir" ]]; then
    cp -r "$dir" "${RESULTS_DIR}/" 2>/dev/null || true
  fi
done

# Ensure JUnit always has data when tests failed.
# Synthesize a minimal failure entry if Playwright wrote nothing (e.g. setup crash before output).
JUNIT_FILE="${RESULTS_DIR}/junit-results.xml"
if [[ "${TEST_EXIT_CODE}" -ne 0 ]]; then
  JUNIT_TESTS=$(python3 -c "
import xml.etree.ElementTree as ET, sys
try:
    root = ET.parse('${JUNIT_FILE}').getroot()
    print(root.get('tests', '0'))
except Exception:
    print('0')
" 2>/dev/null || echo "0")

  if [[ "${JUNIT_TESTS}" == "0" ]]; then
    FAIL_MSG=$(grep -i "error\|Error\|FAIL" "${RESULTS_DIR}/ui-e2e.log" 2>/dev/null | tail -1 \
               || echo "UI tests failed with exit code ${TEST_EXIT_CODE}")
    python3 -c "
import xml.etree.ElementTree as ET, sys
msg = sys.argv[1]
root = ET.Element('testsuites', tests='1', failures='1', errors='0', skipped='0')
suite = ET.SubElement(root, 'testsuite', name='ui-e2e', tests='1', failures='1', errors='0', skipped='0')
tc = ET.SubElement(suite, 'testcase', name='ui-e2e setup', classname='ui-e2e')
ET.SubElement(tc, 'failure', message=msg).text = msg
ET.ElementTree(root).write(sys.argv[2], encoding='unicode', xml_declaration=True)
" "${FAIL_MSG}" "${JUNIT_FILE}"
    echo "Synthesized fallback JUnit (Playwright produced no test output)"
  fi

  # Copy JUnit to shared workspace so the wrapup task can find it even if ORAS pull fails
  SHARED_DIR="${SHARED_DIR:-/shared}"
  mkdir -p "${SHARED_DIR}/results"
  cp "${JUNIT_FILE}" "${SHARED_DIR}/results/junit-ui-e2e.xml" 2>/dev/null || true
fi

if [[ "${TEST_EXIT_CODE}" -ne 0 ]]; then
  echo "UI E2E tests failed (exit code ${TEST_EXIT_CODE})"
  exit 1
fi

echo "All UI E2E tests passed."
