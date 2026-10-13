#!/bin/bash
set -ex

# Argo Rollouts E2E tests adapted from downstream-CI z-stream pipeline.
# Runs three test suites:
#   1. argo-rollouts-manager E2E (cluster-scoped + namespace-scoped)
#   2. upstream argoproj/argo-rollouts E2E
#   3. rollouts-plugin-trafficrouter-openshift E2E
#
# Env vars expected: KUBECONFIG
# Env vars optional: TEST_REPO_URL, BRANCH (used to resolve commit pins from gitops-operator go.mod)

# shellcheck source=./lib/wait-for-resources.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/wait-for-resources.sh"

RESULTS_DIR="${RESULTS_DIR:-/tmp/task-logs}"
mkdir -p "${RESULTS_DIR}"

failed_phases=()

OPERATOR_NAMESPACE=$(oc get deployment openshift-gitops-operator-controller-manager \
  -n openshift-gitops-operator -o jsonpath='{.metadata.namespace}' --ignore-not-found)
OPERATOR_NAMESPACE=${OPERATOR_NAMESPACE:-"openshift-operators"}

SUBSCRIPTION_NAME=$(oc get subscription -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "openshift-gitops-operator")
echo "Using subscription: ${SUBSCRIPTION_NAME} in ${OPERATOR_NAMESPACE}"

# --- Helper functions ---

enable_rollouts_cluster_scoped() {
  oc patch -n "$OPERATOR_NAMESPACE" subscription "$SUBSCRIPTION_NAME" \
    --type merge --patch '{"spec": {"config": {"env": [{"name": "CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES", "value": "argo-rollouts,test-rom-ns-1,rom-ns-1"}]}}}'

  for _ in {1..30}; do
    if oc get deployment openshift-gitops-operator-controller-manager -n "$OPERATOR_NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -q 'CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES'; then
      break
    fi
    echo "Waiting for CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES to be set"
    sleep 5
  done
  wait_for_operator_pods "$OPERATOR_NAMESPACE"
}

enable_rollouts_namespace_scoped() {
  oc patch -n "$OPERATOR_NAMESPACE" subscription "$SUBSCRIPTION_NAME" \
    --type merge --patch '{"spec": {"config": {"env": [{"name": "CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES", "value": ""}]}}}'
  oc patch -n "$OPERATOR_NAMESPACE" subscription "$SUBSCRIPTION_NAME" \
    --type merge --patch '{"spec": {"config": {"env": [{"name": "NAMESPACE_SCOPED_ARGO_ROLLOUTS", "value": "true"}]}}}'

  for _ in {1..30}; do
    if oc get deployment openshift-gitops-operator-controller-manager -n "$OPERATOR_NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -q 'NAMESPACE_SCOPED_ARGO_ROLLOUTS'; then
      break
    fi
    echo "Waiting for NAMESPACE_SCOPED_ARGO_ROLLOUTS to be set"
    sleep 5
  done
  wait_for_operator_pods "$OPERATOR_NAMESPACE"
}

disable_rollouts_config() {
  oc patch -n "$OPERATOR_NAMESPACE" subscription "$SUBSCRIPTION_NAME" \
    --type json --patch '[{"op": "remove", "path": "/spec/config"}]' || true
  wait_for_operator_pods "$OPERATOR_NAMESPACE"
}

# Runs one test phase, copying its output to a log file, and records the phase as failed
# if the command fails. The status has to come from PIPESTATUS: the status of
# `cmd | tee` is tee's, which is always 0, and that is how this script reported
# "All rollouts tests passed" on 2026-10-13 (gitops-catalog-release-1-22-ocp422-kzpcc)
# when every one of its four phases had failed. pipefail is not set script-wide because
# the helpers above pipe oc into `grep -q`, which can SIGPIPE oc and fail the check.
run_phase() {
  local name="$1" log="$2" rc
  shift 2
  "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [[ $rc != 0 ]]; then
    echo "ERROR: ${name} failed (exit ${rc})"
    failed_phases+=("$name")
  fi
}

# Removes -race from an upstream `go test` line. The test image has no C compiler, so
# cgo is off, and with -race every phase that uses it stops before compiling:
#   go: -race requires cgo; enable cgo by setting CGO_ENABLED=1
# The race detector would only watch the test binary -- the operator and the Rollouts
# controller under test run in the cluster -- so nothing about the product is lost.
# If upstream moves the flag, the phase fails with the error above rather than silently.
drop_race_flag() {
  sed -i 's/ -race / /' "$1"
}

cleanup() {
  disable_rollouts_config
  oc delete rollouts -A --all 2>/dev/null || true
  oc delete rolloutmanager -A --all 2>/dev/null || true
}
trap cleanup EXIT

# --- Resolve commit pins from gitops-operator go.mod ---

ROLLOUTS_TMP_DIR=$(mktemp -d)
cd "$ROLLOUTS_TMP_DIR"

TEST_REPO_URL="${TEST_REPO_URL:-https://github.com/redhat-developer/gitops-operator.git}"
BRANCH="${BRANCH:-master}"

echo "Resolving rollouts commit pins from ${TEST_REPO_URL} @ ${BRANCH}"
git clone --depth 1 --branch "${BRANCH}" "${TEST_REPO_URL}" gitops-operator-src

TARGET_ROLLOUT_MANAGER_COMMIT=$(grep 'argoproj-labs/argo-rollouts-manager' \
  gitops-operator-src/go.mod | awk '{print $2}' | sed 's/.*-//' | head -1)

if [[ -z "$TARGET_ROLLOUT_MANAGER_COMMIT" ]]; then
  echo "ERROR: Could not resolve argo-rollouts-manager commit from go.mod"
  exit 1
fi

echo "argo-rollouts-manager commit: ${TARGET_ROLLOUT_MANAGER_COMMIT}"

# --- 1. argo-rollouts-manager E2E tests ---

git clone https://github.com/argoproj-labs/argo-rollouts-manager
cd "$ROLLOUTS_TMP_DIR/argo-rollouts-manager"
git checkout "$TARGET_ROLLOUT_MANAGER_COMMIT"

TARGET_PLUGIN_COMMIT=$(grep 'rollouts-plugin-trafficrouter-openshift' \
  go.mod | awk '{print $2}' | sed 's/.*-//' | head -1 || true)
if [[ -z "$TARGET_PLUGIN_COMMIT" ]]; then
  TARGET_PLUGIN_COMMIT="main"
  echo "rollouts-plugin commit: not pinned in go.mod, using main"
else
  echo "rollouts-plugin commit (from rollouts-manager go.mod): ${TARGET_PLUGIN_COMMIT}"
fi

drop_race_flag hack/run-rollouts-manager-e2e-tests.sh

export GOCACHE="${ROLLOUTS_TMP_DIR}/go-cache"
export GOMODCACHE="${ROLLOUTS_TMP_DIR}/go-mod"
mkdir -p "$GOCACHE" "$GOMODCACHE"

# shellcheck source=/dev/null
source /usr/local/bin/go-cache.sh
go_cache_pull "rollouts-${TARGET_ROLLOUT_MANAGER_COMMIT}"

enable_rollouts_cluster_scoped

echo "=== Running cluster-scoped E2E tests ==="
run_phase "argo-rollouts-manager cluster-scoped" "${RESULTS_DIR}/rollout-manager-cluster-scoped.log" \
  env DISABLE_METRICS=true make test-e2e-cluster-scoped

kubectl delete rolloutmanagers --all -n test-rom-ns-1 || true

enable_rollouts_namespace_scoped

echo "=== Running namespace-scoped E2E tests ==="
run_phase "argo-rollouts-manager namespace-scoped" "${RESULTS_DIR}/rollout-manager-namespace-scoped.log" \
  env DISABLE_METRICS=true make test-e2e-namespace-scoped

kubectl delete rolloutmanagers --all -n test-rom-ns-1 || true

# --- 2. Upstream argo-rollouts E2E tests ---

enable_rollouts_cluster_scoped

cd "$ROLLOUTS_TMP_DIR/argo-rollouts-manager"

echo "=== Running upstream argo-rollouts E2E tests ==="
run_phase "upstream argo-rollouts" "${RESULTS_DIR}/argo-rollouts-upstream.log" \
  env SKIP_RUN_STEP=true hack/run-upstream-argo-rollouts-e2e-tests.sh

# --- 3. rollouts-plugin-trafficrouter-openshift E2E tests ---

echo "=== Running rollouts OpenShift route plugin E2E tests ==="

kubectl delete ns argo-rollouts 2>/dev/null || true
kubectl wait --timeout=5m --for=delete namespace/argo-rollouts 2>/dev/null || true
kubectl create ns argo-rollouts
kubectl config set-context --current --namespace=argo-rollouts

cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: RolloutManager
metadata:
  name: argo-rollout
  namespace: argo-rollouts
spec: {}
EOF

cd "$ROLLOUTS_TMP_DIR"
git clone https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-openshift
cd "$ROLLOUTS_TMP_DIR/rollouts-plugin-trafficrouter-openshift"
git checkout "$TARGET_PLUGIN_COMMIT"

drop_race_flag Makefile

run_phase "rollouts-plugin-trafficrouter-openshift" "${RESULTS_DIR}/rollouts-plugin.log" \
  make test-e2e

# --- Done ---

go_cache_push "rollouts-${TARGET_ROLLOUT_MANAGER_COMMIT}"

if [[ ${#failed_phases[@]} != 0 ]]; then
  echo "ERROR: ${#failed_phases[@]} of 4 rollouts test phases failed:"
  printf '  - %s\n' "${failed_phases[@]}"
  exit 1
fi

echo "All rollouts tests passed"
