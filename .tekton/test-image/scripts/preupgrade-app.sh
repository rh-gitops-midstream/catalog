#!/bin/bash
set -euo pipefail

# The half of an upgrade test that the CSV version cannot tell you: an Argo CD Application
# created *before* the upgrade has to still be there, still owned by the same object, and
# still Synced and Healthy *after* it -- and the operands have to have actually moved to the
# new images rather than the CSV alone reporting success.
#
#   preupgrade-app.sh create   before upgrade-operator.sh
#   preupgrade-app.sh verify   after it
#
# Environment variables expected:
# - KUBECONFIG
# - SHARED_DIR          where create leaves state for verify (default: /shared)
# Optional:
# - GITOPS_NS           ArgoCD instance namespace (default: openshift-gitops)
# - NAMESPACE           operator namespace (default: openshift-gitops-operator)
# - CATALOG_URL         the app's source repo (default: the catalog repo, as the sanity leg uses)
# - CATALOG_REVISION    its revision (default: HEAD)
# - VERIFY_TIMEOUT      seconds to wait for the app after the upgrade (default: 600)

MODE=${1:-}
GITOPS_NS="${GITOPS_NS:-openshift-gitops}"
NAMESPACE="${NAMESPACE:-openshift-gitops-operator}"
SHARED_DIR="${SHARED_DIR:-/shared}"
STATE="${SHARED_DIR}/preupgrade-app.json"
APP_NAME=upgrade-check
APP_NS=upgrade-check-app
APP_REPO="${CATALOG_URL:-https://github.com/rh-gitops-midstream/catalog.git}"
APP_REVISION="${CATALOG_REVISION:-HEAD}"
APP_PATH=.tekton/test-image/config/smoke-app
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-600}"

# The operand that carries the Argo CD image, so "did the operands move" is one lookup.
server_image() {
  oc get deployment openshift-gitops-server -n "$GITOPS_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
}
installed_csv() {
  oc get subscription -n "$NAMESPACE" -o jsonpath='{.items[0].status.installedCSV}' 2>/dev/null || true
}
app_field() {
  oc get application "$APP_NAME" -n "$GITOPS_NS" -o jsonpath="{$1}" 2>/dev/null || true
}

case "$MODE" in
create)
  echo "=== Creating the pre-upgrade Application ==="
  oc create namespace "$APP_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc label namespace "$APP_NS" "argocd.argoproj.io/managed-by=${GITOPS_NS}" --overwrite >/dev/null

  # The operator has to project its RBAC into the namespace before the app can sync there.
  for _ in $(seq 1 30); do
    oc get rolebinding -n "$APP_NS" 2>/dev/null | grep -q "$GITOPS_NS" && break
    sleep 2
  done

  cat <<YAML | oc apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${GITOPS_NS}
spec:
  project: default
  source:
    repoURL: ${APP_REPO}
    targetRevision: ${APP_REVISION}
    path: ${APP_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${APP_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
YAML

  for _ in $(seq 1 60); do
    [[ "$(app_field .status.sync.status)" == "Synced" && "$(app_field .status.health.status)" == "Healthy" ]] && break
    sleep 5
  done
  SYNC=$(app_field .status.sync.status); HEALTH=$(app_field .status.health.status)
  if [[ "$SYNC" != "Synced" || "$HEALTH" != "Healthy" ]]; then
    echo "ERROR: the pre-upgrade app did not become Synced/Healthy (sync=${SYNC:-none} health=${HEALTH:-none})"
    oc get application "$APP_NAME" -n "$GITOPS_NS" -o yaml || true
    exit 1
  fi

  mkdir -p "$SHARED_DIR"
  cat > "$STATE" <<JSON
{
  "uid": "$(app_field .metadata.uid)",
  "creationTimestamp": "$(app_field .metadata.creationTimestamp)",
  "revision": "$(app_field .status.sync.revision)",
  "serverImage": "$(server_image)",
  "csv": "$(installed_csv)"
}
JSON
  echo "Pre-upgrade state recorded in ${STATE}:"
  cat "$STATE"
  ;;

verify)
  echo "=== Verifying the pre-upgrade Application survived ==="
  [[ -r "$STATE" ]] || { echo "ERROR: ${STATE} not found -- did the create step run?"; exit 1; }
  BEFORE_UID=$(jq -r .uid "$STATE"); BEFORE_IMAGE=$(jq -r .serverImage "$STATE"); BEFORE_CSV=$(jq -r .csv "$STATE")

  failures=0
  fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
  pass() { echo "PASS: $1"; }

  # Give the app time: the operands restart under it during the upgrade.
  deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [[ "$(app_field .status.sync.status)" == "Synced" && "$(app_field .status.health.status)" == "Healthy" ]] && break
    sleep 10
  done

  AFTER_UID=$(app_field .metadata.uid)
  if [[ -z "$AFTER_UID" ]]; then
    fail "the Application no longer exists after the upgrade"
  elif [[ "$AFTER_UID" != "$BEFORE_UID" ]]; then
    fail "the Application was replaced during the upgrade (uid ${BEFORE_UID} -> ${AFTER_UID})"
  else
    pass "the Application survived the upgrade with the same uid"
  fi

  SYNC=$(app_field .status.sync.status); HEALTH=$(app_field .status.health.status)
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    pass "the Application is still Synced and Healthy"
  else
    fail "the Application is sync=${SYNC:-none} health=${HEALTH:-none} after the upgrade"
    oc get application "$APP_NAME" -n "$GITOPS_NS" -o yaml || true
  fi

  AFTER_CSV=$(installed_csv)
  if [[ -n "$AFTER_CSV" && "$AFTER_CSV" != "$BEFORE_CSV" ]]; then
    pass "CSV moved: ${BEFORE_CSV} -> ${AFTER_CSV}"
  else
    fail "CSV did not change (still ${AFTER_CSV:-none})"
  fi

  # The CSV reporting Succeeded does not mean the operands were rewritten; the operator
  # reconciles them afterwards, and that is where an upgrade actually shows up for a user.
  AFTER_IMAGE=$(server_image)
  if [[ -n "$AFTER_IMAGE" && "$AFTER_IMAGE" != "$BEFORE_IMAGE" ]]; then
    pass "operands moved: openshift-gitops-server image ${BEFORE_IMAGE##*@} -> ${AFTER_IMAGE##*@}"
  else
    fail "openshift-gitops-server still runs ${AFTER_IMAGE:-none} after the upgrade"
  fi

  # Leave the cluster as the suites expect to find it.
  oc delete application "$APP_NAME" -n "$GITOPS_NS" --ignore-not-found >/dev/null 2>&1 || true
  oc delete namespace "$APP_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  echo "=== ${failures} check(s) failed ==="
  [[ $failures -eq 0 ]]
  ;;

*)
  echo "usage: $0 create|verify" >&2
  exit 2
  ;;
esac
