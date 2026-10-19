#!/bin/bash
set -ex

# Environment variables expected:
# - OPENSHIFT_VERSION (e.g. "4.20" or "4.20.19")
# - NAMESPACE
# - INSTALL_TIMEOUT
# - KUBECONFIG
# - OPERATOR_CHANNEL (default: latest)
# - OPERATOR_VERSION (optional, pins to a specific CSV version)

# shellcheck source=./lib/wait-for-resources.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/wait-for-resources.sh"

MINOR_VERSION=$(echo "${OPENSHIFT_VERSION}" | grep -oP '^\d+\.\d+')

# The catalog under test comes from the Snapshot. It used to be derived from the OpenShift
# version alone -- catalog:v${MINOR_VERSION} -- which is a floating tag pointing at the last
# build pushed from main. That meant every run, in every tier, installed main rather than
# the change under review, and nothing said so. On 2026-10-11 a release-candidate run for
# v1.22.2 silently installed v1.22.1: the Snapshot's catalog had v1.22.2, the floating tag
# did not, and the Snapshot's image was never consulted.
#
# The fallback is kept for runs with no Snapshot behind them -- a hand-written PipelineRun
# -- but which source was used is logged either way, because the failure mode this replaces
# was invisible.
if [[ -n "${CATALOG_IMAGE:-}" ]]; then
  echo "Catalog image: ${CATALOG_IMAGE} (from the Snapshot under test)"
else
  CATALOG_IMAGE="quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v${MINOR_VERSION}"
  echo "WARNING: no catalog image was passed in; falling back to the floating tag"
  echo "WARNING:   ${CATALOG_IMAGE}"
  echo "WARNING: this is whatever was last pushed from main, NOT the change under test."
fi

echo "Installing GitOps Operator from catalog: ${CATALOG_IMAGE}"
echo "OpenShift version: ${OPENSHIFT_VERSION} (minor: ${MINOR_VERSION})"
echo "Target namespace: ${NAMESPACE}"

# 1. Inject quay pull credentials into cluster
if [[ -f "/quay-pull-credentials/.dockerconfigjson" ]]; then
  # 1a. Patch global pull-secret (may take time to propagate on HyperShift)
  echo "Injecting quay pull credentials into cluster global pull-secret..."
  # Tracing off while the pull secret is in a variable: `set -x` would print every
  # registry credential on the cluster into the log, and the log is uploaded to quay.
  { set +x; } 2>/dev/null
  EXISTING=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  MERGED=$(echo "$EXISTING" | python3 -c "
import json, sys
existing = json.load(sys.stdin)
with open('/quay-pull-credentials/.dockerconfigjson') as f:
    extra = json.load(f)
existing.setdefault('auths', {}).update(extra.get('auths', {}))
print(json.dumps(existing))
")
  oc set data secret/pull-secret -n openshift-config --from-literal=.dockerconfigjson="$MERGED"
  echo "Injected $(echo "$MERGED" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['auths']))" 2>/dev/null) registry credentials into cluster pull-secret"
  unset EXISTING MERGED
  set -x

  # 1b. Create additional-pull-secret in kube-system (HyperShift-native mechanism).
  # The Hosted Cluster Config Operator detects this secret and deploys a DaemonSet
  # that writes credentials to /var/lib/kubelet/config.json on each node.
  echo "Creating additional-pull-secret in kube-system for HyperShift node credential injection..."
  oc create secret generic additional-pull-secret \
    -n kube-system \
    --from-file=.dockerconfigjson=/quay-pull-credentials/.dockerconfigjson \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | oc apply -f -

  # Wait for the syncer DaemonSet to appear and propagate to all nodes
  echo "Waiting for pull-secret syncer DaemonSet..."
  SYNC_TIMEOUT=300
  SYNC_START=$(date +%s)
  while true; do
    DS_NAME=$(oc get daemonset -n kube-system -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -i 'pull-secret' | head -1 || true)

    if [[ -n "$DS_NAME" ]]; then
      DESIRED=$(oc get ds "$DS_NAME" -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
      READY=$(oc get ds "$DS_NAME" -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
      if [[ "$DESIRED" -gt 0 && "$DESIRED" == "$READY" ]]; then
        echo "Pull-secret syncer DaemonSet $DS_NAME is ready ($READY/$DESIRED nodes)"
        break
      fi
      echo "  Syncer DaemonSet $DS_NAME: $READY/$DESIRED nodes ready..."
    fi

    ELAPSED=$(( $(date +%s) - SYNC_START ))
    if [[ $ELAPSED -ge $SYNC_TIMEOUT ]]; then
      echo "WARNING: Pull-secret syncer not fully ready within ${SYNC_TIMEOUT}s, continuing anyway"
      oc get daemonset -n kube-system 2>/dev/null || true
      break
    fi
    sleep 15
  done
else
  echo "WARNING: No quay pull credentials found at /quay-pull-credentials/.dockerconfigjson"
fi

# CATALOG_ONLY: stop once the catalog under test is being served, and install nothing.
# Set by hive-suite-leg when the leg starts with run-upgrade-baseline.sh, whose suite
# installs the previous version itself and requires a cluster without the operator --
# it refuses to start if the operator namespace already exists, hence step 2 is skipped.
if [[ "${CATALOG_ONLY:-false}" != "true" ]]; then
# 2. Ensure the operator namespace exists
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
fi

# 3. Create CatalogSource
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: gitops-stage
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${CATALOG_IMAGE}
  displayName: GitOps Stage Catalog
  publisher: Konflux
  updateStrategy:
    registryPoll:
      interval: 30m
EOF

if [[ "${CATALOG_ONLY:-false}" == "true" ]]; then
  echo "CATALOG_ONLY: waiting for the gitops-stage catalog to serve the operator package..."
  for _ in $(seq 1 60); do
    if oc get packagemanifest -n openshift-marketplace -l catalog=gitops-stage \
         -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -qw openshift-gitops-operator; then
      echo "gitops-stage serves openshift-gitops-operator; channels:"
      oc get packagemanifest -n openshift-marketplace -l catalog=gitops-stage \
        -o jsonpath='{range .items[*].status.channels[*]}{.name}{" -> "}{.currentCSV}{"\n"}{end}' || true
      echo "CATALOG_ONLY: not installing the operator; the leg's first suite does"
      exit 0
    fi
    sleep 10
  done
  echo "ERROR: gitops-stage did not serve openshift-gitops-operator within 10 minutes"
  oc get catalogsource gitops-stage -n openshift-marketplace -o yaml || true
  exit 1
fi

# 4. Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: gitops-operator-group
  namespace: ${NAMESPACE}
spec: {}
EOF

# 5. Create Subscription
OPERATOR_CHANNEL="${OPERATOR_CHANNEL:-latest}"

SUBSCRIPTION_YAML=$(cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gitops-operator-konflux
  namespace: ${NAMESPACE}
spec:
  channel: ${OPERATOR_CHANNEL}
  name: openshift-gitops-operator
  source: gitops-stage
  sourceNamespace: openshift-marketplace
EOF
)

if [[ -n "${OPERATOR_VERSION:-}" ]]; then
  SUBSCRIPTION_YAML+="
  startingCSV: openshift-gitops-operator.v${OPERATOR_VERSION}"
fi

echo "$SUBSCRIPTION_YAML" | oc apply -f -
echo "Subscription created: channel=${OPERATOR_CHANNEL}${OPERATOR_VERSION:+, startingCSV=v${OPERATOR_VERSION}}"

# 6. Wait for installation
if ! wait_for_csv gitops-operator-konflux "${NAMESPACE}" "${INSTALL_TIMEOUT}"; then
  exit 1
fi

echo "Operator installed successfully (CSV: ${CSV_NAME})"

# --- Assert we installed what the catalog actually advertises -------------------------
#
# The installed version has always been recorded -- in this log, in the catalog-results
# row, and in the results directory path -- and never compared against anything. That is
# how a release-candidate run for v1.22.2 spent weeks reporting green while installing
# v1.22.1 from a floating tag: the row said v1.22.1, accurately, and nothing objected.
#
# So: ask the catalog under test what it considers the head of this channel, and refuse
# to continue if OLM resolved something else. With OPERATOR_VERSION pinned the head is
# deliberately not what we want, so compare against the pin instead.
#
# Determining the expectation is best-effort -- a packagemanifest we cannot read is not
# proof of a problem -- but a mismatch we *can* see is fatal. The point is that silence
# must stop meaning success.
if [[ -n "${OPERATOR_VERSION:-}" ]]; then
  EXPECTED_CSV="openshift-gitops-operator.v${OPERATOR_VERSION}"
  EXPECTED_FROM="the pinned OPERATOR_VERSION"
else
  EXPECTED_CSV=$(oc get packagemanifests -n openshift-marketplace -l "catalog=gitops-stage" -o json 2>/dev/null \
    | jq -r --arg ch "${OPERATOR_CHANNEL}" '
        .items[]
        | select(.status.packageName == "openshift-gitops-operator")
        | .status.channels[]
        | select(.name == $ch)
        | .currentCSV' 2>/dev/null | head -1)
  EXPECTED_FROM="the head of channel ${OPERATOR_CHANNEL} in the catalog under test"
fi

if [[ -z "${EXPECTED_CSV}" ]]; then
  echo "WARNING: could not determine the expected CSV from the catalog; skipping the"
  echo "WARNING: self-consistency check. Installed: ${CSV_NAME}"
elif [[ "${EXPECTED_CSV}" != "${CSV_NAME}" ]]; then
  echo "::error::installed the wrong operator version"
  echo "  expected : ${EXPECTED_CSV}  (${EXPECTED_FROM})"
  echo "  installed: ${CSV_NAME}"
  echo "The catalog under test and the installed operator disagree. Testing would"
  echo "produce a result that looks valid and describes the wrong build."
  exit 1
else
  echo "Version check: ${CSV_NAME} matches ${EXPECTED_FROM}"
fi

# 7. Fallback: inject pull credentials into openshift-gitops namespace
# In case the additional-pull-secret DaemonSet (step 1b) hasn't fully propagated
# by the time ArgoCD pods start, this background loop links a namespace-scoped
# pull secret to service accounts and restarts stuck pods.
SA_PATCH_PID=""
if [[ -f "/quay-pull-credentials/.dockerconfigjson" ]]; then
  echo ""
  echo "=========================================="
  echo "Starting background pull-secret injection"
  echo "=========================================="
  (
    while true; do
      if oc get namespace openshift-gitops &>/dev/null; then
        # Ensure pull secret exists in the namespace
        oc create secret generic quay-mirror-pull \
          --from-file=.dockerconfigjson=/quay-pull-credentials/.dockerconfigjson \
          --type=kubernetes.io/dockerconfigjson \
          -n openshift-gitops \
          --dry-run=client -o yaml | oc apply -f - &>/dev/null

        # Link to all SAs that don't already have it
        for sa in $(oc get sa -n openshift-gitops -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
          if ! oc get sa "$sa" -n openshift-gitops -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null | grep -q quay-mirror-pull; then
            oc patch sa "$sa" -n openshift-gitops --type=json \
              -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"quay-mirror-pull"}}]' &>/dev/null || true
          fi
        done

        # Restart pods stuck on image pull errors so they pick up the new SA credentials
        STUCK=$(oc get pods -n openshift-gitops 2>/dev/null | grep -E 'ImagePullBackOff|ErrImagePull' | awk '{print $1}')
        for pod in $STUCK; do
          echo "  [pull-secret-injector] Restarting stuck pod: $pod"
          oc delete pod "$pod" -n openshift-gitops --grace-period=0 &>/dev/null || true
        done
      fi
      sleep 10
    done
  ) &
  SA_PATCH_PID=$!
  trap 'kill "${SA_PATCH_PID:-}" 2>/dev/null || true' EXIT
  echo "Background pull-secret injection started (PID: $SA_PATCH_PID)"
fi

# 8. Verify all related images are available at mirrors
echo ""
echo "=========================================="
echo "Verifying related images are available"
echo "=========================================="
python3 /usr/local/bin/verify-images.py || {
  echo "WARNING: Some images are not available at their mirror locations."
  echo "ArgoCD pods may fail with ImagePullBackOff."
}

echo ""
echo "=========================================="
echo "DEBUG INFO: Post-Installation State"
echo "=========================================="
echo ""

echo "--- CatalogSource Status ---"
oc get catalogsource gitops-stage -n openshift-marketplace -o yaml || true
echo ""

echo "--- Subscription Status ---"
oc get subscription gitops-operator-konflux -n "${NAMESPACE}" -o yaml || true
echo ""

echo "--- ClusterServiceVersion Status ---"
oc get csv "${CSV_NAME}" -n "${NAMESPACE}" -o yaml || true
echo ""

echo "--- All Pods in ${NAMESPACE} ---"
oc get pods -n "${NAMESPACE}" -o wide || true
echo ""

echo "--- Events in ${NAMESPACE} ---"
oc get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' || true
echo ""

echo "--- Operator Deployment ---"
oc get deployments -n "${NAMESPACE}" -o wide || true
echo ""

echo "=========================================="

# 9. Verify default ArgoCD instance is ready
echo ""
echo "=========================================="
echo "Verifying default ArgoCD instance"
echo "=========================================="

echo "Waiting for openshift-gitops namespace and ArgoCD deployments to appear..."
for _ in {1..60}; do
  if oc get deployment openshift-gitops-server -n openshift-gitops &>/dev/null; then
    break
  fi
  sleep 10
done

if ! oc get deployment openshift-gitops-server -n openshift-gitops &>/dev/null; then
  echo "ERROR: ArgoCD deployments not created after 10 minutes"
  oc get ns openshift-gitops 2>/dev/null || echo "Namespace openshift-gitops does not exist"
  oc get argocd -n openshift-gitops 2>/dev/null || true
  oc get pods -n openshift-gitops -o wide 2>/dev/null || true
  oc get events -n openshift-gitops --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
  echo "--- IDMS on cluster ---"
  oc get imagedigestmirrorset 2>/dev/null || echo "No IDMS"
  echo "--- Operator logs ---"
  oc logs deployment/openshift-gitops-operator-controller-manager -n openshift-gitops-operator -c manager --tail=50 2>/dev/null || true
  exit 1
fi

echo "ArgoCD deployments found, waiting for them to become available..."
for deploy in openshift-gitops-server openshift-gitops-repo-server; do
  if ! wait_for_deployment "$deploy" openshift-gitops 600s; then
    exit 1
  fi
  echo "$deploy is ready"
done

# application-controller is a StatefulSet, not a Deployment
if oc get statefulset openshift-gitops-application-controller -n openshift-gitops &>/dev/null; then
  if ! wait_for_statefulset openshift-gitops-application-controller openshift-gitops 600s; then
    exit 1
  fi
  echo "openshift-gitops-application-controller is ready"
else
  echo "WARNING: openshift-gitops-application-controller statefulset not found, skipping"
fi

echo "ArgoCD instance is ready"

# Stop background pull-secret injection
if [[ -n "${SA_PATCH_PID}" ]]; then
  kill $SA_PATCH_PID 2>/dev/null || true
  wait $SA_PATCH_PID 2>/dev/null || true
  echo "Stopped background pull-secret injection"
fi

# 10. Collect cluster-wide debug info (on success)
echo ""
echo "=========================================="
echo "DEBUG INFO: Cluster Image Configuration"
echo "=========================================="

echo "--- ImageDigestMirrorSet ---"
oc get imagedigestmirrorset -o yaml 2>/dev/null || echo "No IDMS found"
echo ""

echo "--- ImageContentSourcePolicy ---"
oc get imagecontentsourcepolicy -o yaml 2>/dev/null || echo "No ICSP found"
echo ""

echo "--- openshift-gitops namespace pods ---"
oc get pods -n openshift-gitops -o wide 2>/dev/null || true
echo ""

echo "--- openshift-gitops namespace events (last 5 min) ---"
oc get events -n openshift-gitops --sort-by='.lastTimestamp' 2>/dev/null | tail -40 || true
echo ""

echo "--- openshift-gitops pod descriptions (non-Running) ---"
for pod in $(oc get pods -n openshift-gitops -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  echo "=== Pod: $pod ==="
  oc describe pod "$pod" -n openshift-gitops 2>/dev/null | grep -A5 -E 'State:|Image:|Warning|Error|Back-off|ImagePull' || true
  echo ""
done

echo "=========================================="

# 11. Verify pull-secret propagated to nodes
if [[ -f "/quay-pull-credentials/.dockerconfigjson" ]]; then
  echo ""
  echo "=========================================="
  echo "Verifying pull-secret propagation to nodes"
  echo "=========================================="
  EXPECTED_REPOS=$(python3 -c "
import json
with open('/quay-pull-credentials/.dockerconfigjson') as f:
    d = json.load(f)
for k in sorted(d.get('auths', {})):
    print(k)
" 2>/dev/null)
  # Tracing off again: the cluster pull secret is in a variable until the loop ends.
  { set +x; } 2>/dev/null
  CLUSTER_SECRET=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d)
  MISSING=0
  while IFS= read -r repo; do
    if echo "$CLUSTER_SECRET" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '$repo' in d.get('auths',{}) else 1)" 2>/dev/null; then
      echo "  OK   $repo"
    else
      echo "  MISS $repo"
      MISSING=$((MISSING + 1))
    fi
  done <<< "$EXPECTED_REPOS"
  unset CLUSTER_SECRET
  set -x
  if [[ $MISSING -gt 0 ]]; then
    echo "WARNING: $MISSING repo(s) missing from cluster pull-secret"
  else
    echo "Pull-secret contains injected credentials"
  fi
fi
