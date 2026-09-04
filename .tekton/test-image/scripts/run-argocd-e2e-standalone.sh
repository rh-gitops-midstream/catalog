#!/bin/bash
# Run the upstream Argo CD e2e suite against a STANDALONE Argo CD built from the
# release candidate, on the leg's Hive-claimed cluster.
#
# This is the single-script equivalent of what the gitops-catalog-argocd-e2e pipeline
# does across three tasks (extract-argocd-image -> deploy-argocd -> test-argocd). The
# z-stream leg runs suites as scripts inside one Task, so the sequence lives here.
#
# WHY NOT TEST THE OPERATOR-INSTALLED INSTANCE
#
# The obvious idea — point the suite at the openshift-gitops instance the operator
# already installed — cannot work, and fails in a way that looks like flakiness rather
# than a design error. The e2e fixture owns Argo CD's configuration: EnsureCleanState and
# the various helpers (SetResourceOverrides, SetOIDCConfig, SetParamInRBACConfigMap,
# updateSettings) rewrite argocd-cm and argocd-rbac-cm in ARGOCD_E2E_NAMESPACE before and
# during tests. The GitOps operator reconciles exactly those ConfigMaps from the ArgoCD
# CR and reverts them. The suite and the operator would fight, per test, forever.
#
# So the leg deploys its own Argo CD from the release-candidate image and tests that.
# The operator's packaging of Argo CD is covered by the other five legs, which exercise
# it the way it is meant to be used.
#
# ARGOCD_E2E_REMOTE is an upstream flag (fixture.IsRemote()), but note what it actually
# does: it only makes the fixture push test repository state to a real in-cluster git
# server instead of using a local path. It does not make the suite hands-off about Argo
# CD's configuration. That is the detail that makes the operator-instance idea look
# plausible when it is not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_NAMESPACE="${ARGOCD_E2E_NAMESPACE:-argocd-e2e}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-gitops-operator}"
GITOPS_NAMESPACE="${GITOPS_NAMESPACE:-openshift-gitops}"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- 1. which Argo CD version is this release candidate? -----------------------------
#
# Both the upstream manifests we deploy and the e2e suite we compile have to match the
# server image, or the suite tests behaviour the server does not have. The existing
# standalone scenario pins these as pipeline params (currently v2.14.1 for both); on a
# z-stream leg the version is a property of the release under test, so ask the operator's
# own running server rather than carrying a default that silently goes stale.
if [[ -z "${ARGOCD_VERSION:-}" ]]; then
  RAW=$(oc exec -n "${GITOPS_NAMESPACE}" deploy/openshift-gitops-server -- \
          argocd-server version --short 2>/dev/null | head -1 || true)
  ARGOCD_VERSION=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' <<<"${RAW}" | head -1 || true)
  [[ -n "${ARGOCD_VERSION}" ]] \
    || die "could not determine the Argo CD version from the operator-installed server in ${GITOPS_NAMESPACE}, and ARGOCD_VERSION was not set. Refusing to guess: a mismatched version deploys one Argo CD and tests another."
  echo "Release candidate ships Argo CD ${ARGOCD_VERSION}"
fi

# --- 2. the release-candidate Argo CD image ------------------------------------------
#
# The standalone pipeline parses the File-Based Catalog to find this. Here the operator
# is already installed on the cluster, so its CSV lists the same image in relatedImages —
# fewer moving parts, and guaranteed to be the image this operator would actually use.
CSV=$(oc get csv -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.items[?(@.status.phase=="Succeeded")].metadata.name}' 2>/dev/null \
        | tr ' ' '\n' | grep -i gitops | head -1 || true)
[[ -n "${CSV}" ]] || die "no Succeeded gitops CSV in ${OPERATOR_NAMESPACE} — did install-operator run?"

ARGOCD_SERVER_IMAGE=$(oc get csv "${CSV}" -n "${OPERATOR_NAMESPACE}" -o json 2>/dev/null \
  | jq -r '[.spec.relatedImages[]? | select(.name|test("argocd|argo-cd";"i")) | .image]
           | map(select(test("argocd-rhel|argo-cd")))
           | first // empty')
[[ -n "${ARGOCD_SERVER_IMAGE}" ]] \
  || die "could not find an Argo CD image in relatedImages of CSV ${CSV}"

echo "Release-candidate Argo CD image: ${ARGOCD_SERVER_IMAGE}"

# --- 3. deploy it standalone ----------------------------------------------------------
echo "Deploying standalone Argo CD ${ARGOCD_VERSION} into ${E2E_NAMESPACE}..."
NAMESPACE="${E2E_NAMESPACE}" \
ARGOCD_VERSION="${ARGOCD_VERSION}" \
ARGOCD_SERVER_IMAGE="${ARGOCD_SERVER_IMAGE}" \
  "${SCRIPT_DIR}/deploy-argocd-standalone.sh"

# --- 4. the e2e fixture's known admin password ----------------------------------------
#
# Upstream applies test/manifests/base, whose only patch over the production manifests
# sets argocd-secret to a known bcrypt hash so the fixture can log in as admin/password.
# deploy-argocd-standalone.sh applies manifests/install.yaml, which does not include it,
# and then reads whatever random password Argo CD generated. Either works, as long as the
# suite is told the truth — so set the known one, which is what upstream tests assume.
echo "Setting the e2e fixture's known admin password..."
oc patch secret argocd-secret -n "${E2E_NAMESPACE}" --type merge -p '{
  "stringData": {
    "admin.password": "$2a$10$RncPyHW/B5ll2Z3J8s.IBOnbZ9uoJ4JhHLKzj5lzG/kU1KN1Oj3/K",
    "admin.passwordMtime": "2019-03-20T17:54:53Z"
  }
}' >/dev/null
# The server caches the password; restart so the patched hash takes effect before login.
oc rollout restart deployment/argocd-server -n "${E2E_NAMESPACE}" >/dev/null
oc rollout status deployment/argocd-server -n "${E2E_NAMESPACE}" --timeout=5m

ARGOCD_ADMIN_PASSWORD=password

ARGOCD_SERVER=$(oc get route argocd-server -n "${E2E_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
[[ -n "${ARGOCD_SERVER}" ]] || die "no argocd-server route in ${E2E_NAMESPACE} after deploy"

# --- 5. hand over to the shared runner ------------------------------------------------
#
# Standalone component names, not the operator's openshift-gitops-* ones.
export ARGOCD_NAMESPACE="${E2E_NAMESPACE}"
export ARGOCD_SERVER ARGOCD_ADMIN_PASSWORD ARGOCD_SERVER_IMAGE
export ARGOCD_SERVER_NAME="argocd-server"
export ARGOCD_REPO_SERVER_NAME="argocd-repo-server"
export ARGOCD_APPLICATION_CONTROLLER_NAME="argocd-application-controller"
export ARGOCD_REDIS_NAME="argocd-redis"

# The suite source must match the deployed server, so both come from ARGOCD_VERSION.
export TEST_REPO_URL="${ARGOCD_TEST_REPO_URL:-https://github.com/argoproj/argo-cd.git}"
export BRANCH="${ARGOCD_VERSION}"
export TEST_REPO_BRANCH="${ARGOCD_VERSION}"

cat <<EOF
--- argocd-e2e (standalone, release candidate) ---
  namespace   : ${ARGOCD_NAMESPACE}
  server      : ${ARGOCD_SERVER}
  image       : ${ARGOCD_SERVER_IMAGE}
  version     : ${ARGOCD_VERSION}
  test source : ${TEST_REPO_URL} @ ${BRANCH}
--------------------------------------------------
EOF

exec "${SCRIPT_DIR}/run-argocd-e2e-tests.sh"
