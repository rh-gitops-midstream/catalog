#!/bin/bash
# Run the upstream Argo CD e2e suite against the OPERATOR-INSTALLED Argo CD.
#
# run-argocd-e2e-tests.sh is written for the standalone path: deploy-argocd stands an
# Argo CD up from the catalog's server image and hands the suite eight values as task
# results. It does not deploy anything itself — it says so, and then assumes the instance
# is already there.
#
# On a z-stream leg the instance *is* already there, installed by the operator, so those
# same values exist and only need discovering. That is what this wrapper does, and it is
# what the downstream z-stream argocd-e2e-tests task does too: it derives the Argo CD
# version by exec'ing into the running openshift-gitops-server rather than being told.
#
# The distinction matters when reading results. This tests the Argo CD the operator ships
# and manages. The existing gitops-catalog-argocd-e2e scenario tests a standalone Argo CD
# built straight from the catalog image. Both are worth having; they are not the same
# thing, and a pass here does not imply a pass there.
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "Discovering the operator-installed Argo CD in namespace ${ARGOCD_NAMESPACE}..."

oc get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 \
  || die "namespace ${ARGOCD_NAMESPACE} does not exist — did install-operator run and did the default ArgoCD instance come up?"

# Wait for the instance rather than assuming it is ready. install-operator returns once
# the CSV succeeds, but the operator then still has to reconcile the default ArgoCD CR.
echo "Waiting for the ArgoCD instance to be Available..."
for i in $(seq 1 60); do
  PHASE=$(oc get argocd -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [[ "${PHASE}" == "Available" ]] && break
  echo "  [${i}/60] phase=${PHASE:-<none>}"
  sleep 10
done
[[ "${PHASE:-}" == "Available" ]] \
  || die "ArgoCD instance did not become Available (phase=${PHASE:-<none>})"

# --- the eight values run-argocd-e2e-tests.sh expects -------------------------------

# Hostname only: the suite builds https://${ARGOCD_SERVER}/healthz itself.
ARGOCD_SERVER=$(oc get route openshift-gitops-server -n "${ARGOCD_NAMESPACE}" \
                  -o jsonpath='{.spec.host}' 2>/dev/null || true)
[[ -n "${ARGOCD_SERVER}" ]] \
  || die "no openshift-gitops-server route in ${ARGOCD_NAMESPACE}. The standalone path uses a route named argocd-server; the operator names it openshift-gitops-server."

ARGOCD_ADMIN_PASSWORD=$(oc get secret openshift-gitops-cluster -n "${ARGOCD_NAMESPACE}" \
                          -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d || true)
[[ -n "${ARGOCD_ADMIN_PASSWORD}" ]] \
  || die "could not read admin.password from secret openshift-gitops-cluster in ${ARGOCD_NAMESPACE}"

# Optional. The suite uses it to extract a matching argocd CLI, and falls back to a
# released binary when unset — so a failure to resolve it is a warning, not fatal.
ARGOCD_SERVER_IMAGE=$(oc get deployment openshift-gitops-server -n "${ARGOCD_NAMESPACE}" \
                        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [[ -z "${ARGOCD_SERVER_IMAGE}" ]]; then
  echo "WARNING: could not resolve the server image; the suite will fall back to a released argocd CLI."
fi

# Component names. The operator prefixes everything with openshift-gitops-. Note the
# application controller is a StatefulSet here, not a Deployment as in the standalone
# path — the suite only uses these as names, but it is worth knowing if it ever starts
# treating them as Deployments.
ARGOCD_SERVER_NAME="openshift-gitops-server"
ARGOCD_REPO_SERVER_NAME="openshift-gitops-repo-server"
ARGOCD_APPLICATION_CONTROLLER_NAME="openshift-gitops-application-controller"
ARGOCD_REDIS_NAME="openshift-gitops-redis"

for d in "${ARGOCD_SERVER_NAME}" "${ARGOCD_REPO_SERVER_NAME}" "${ARGOCD_REDIS_NAME}"; do
  oc get deployment "$d" -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 \
    || echo "WARNING: expected deployment $d not found in ${ARGOCD_NAMESPACE}"
done

export ARGOCD_NAMESPACE ARGOCD_SERVER ARGOCD_ADMIN_PASSWORD ARGOCD_SERVER_IMAGE
export ARGOCD_SERVER_NAME ARGOCD_REPO_SERVER_NAME ARGOCD_APPLICATION_CONTROLLER_NAME ARGOCD_REDIS_NAME

cat <<EOF
--- discovered ---
  namespace  : ${ARGOCD_NAMESPACE}
  server     : ${ARGOCD_SERVER}
  image      : ${ARGOCD_SERVER_IMAGE:-<unresolved>}
  password   : <redacted, ${#ARGOCD_ADMIN_PASSWORD} chars>
------------------
EOF

exec "${SCRIPT_DIR}/run-argocd-e2e-tests.sh"
