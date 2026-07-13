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

exit_code=0
failed=0

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

export GOCACHE="${ROLLOUTS_TMP_DIR}/go-cache"
export GOMODCACHE="${ROLLOUTS_TMP_DIR}/go-mod"
mkdir -p "$GOCACHE" "$GOMODCACHE"

# shellcheck source=/dev/null
source /usr/local/bin/go-cache.sh
go_cache_pull "rollouts-${TARGET_ROLLOUT_MANAGER_COMMIT}"

enable_rollouts_cluster_scoped

echo "=== Running cluster-scoped E2E tests ==="
DISABLE_METRICS=true make test-e2e-cluster-scoped 2>&1 | tee "${RESULTS_DIR}/rollout-manager-cluster-scoped.log" || exit_code=$?
if [[ $exit_code != 0 ]]; then
  failed=$exit_code
  exit_code=0
fi

kubectl delete rolloutmanagers --all -n test-rom-ns-1 || true

enable_rollouts_namespace_scoped

echo "=== Running namespace-scoped E2E tests ==="
DISABLE_METRICS=true make test-e2e-namespace-scoped 2>&1 | tee "${RESULTS_DIR}/rollout-manager-namespace-scoped.log" || exit_code=$?
if [[ $exit_code != 0 ]]; then
  failed=$exit_code
  exit_code=0
fi

kubectl delete rolloutmanagers --all -n test-rom-ns-1 || true

# --- 2. Upstream argo-rollouts E2E tests ---

enable_rollouts_cluster_scoped

cd "$ROLLOUTS_TMP_DIR/argo-rollouts-manager"

echo "=== Running upstream argo-rollouts E2E tests ==="
SKIP_RUN_STEP=true hack/run-upstream-argo-rollouts-e2e-tests.sh 2>&1 | tee "${RESULTS_DIR}/argo-rollouts-upstream.log" || exit_code=$?
if [[ $exit_code != 0 ]]; then
  failed=$exit_code
  exit_code=0
fi

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

make test-e2e 2>&1 | tee "${RESULTS_DIR}/rollouts-plugin.log" || exit_code=$?
if [[ $exit_code != 0 ]]; then
  failed=$exit_code
fi

# --- Done ---

go_cache_push "rollouts-${TARGET_ROLLOUT_MANAGER_COMMIT}"

if [[ $failed != 0 ]]; then
  echo "ERROR: One or more rollouts test suites failed"
  exit 1
fi

echo "All rollouts tests passed"
