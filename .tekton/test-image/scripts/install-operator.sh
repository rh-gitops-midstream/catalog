#!/bin/bash
set -ex

# Pull-secret content must never reach xtrace: this script runs with `set -x` and its
# output is uploaded as a task-log artifact. Secrets are therefore only ever held in files
# under a private directory outside the log directory, and only their paths appear on a
# command line. The read retries, because a single `oc get` against a freshly claimed
# cluster can time out, and an empty read used to fail the install as a JSON parse error.
SECRET_DIR=$(mktemp -d)
chmod 700 "$SECRET_DIR"
trap 'rm -rf "$SECRET_DIR"' EXIT

read_cluster_pull_secret() {
  { set +x; } 2>/dev/null
  local dest=$1 attempt
  for attempt in 1 2 3 4 5; do
    if oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
         | base64 -d > "$dest" 2>/dev/null && [[ -s "$dest" ]]; then
      set -x
      return 0
    fi
    echo "reading openshift-config/pull-secret failed (attempt ${attempt}/5); retrying in 10s" >&2
    sleep 10
  done
  : > "$dest"
  echo "ERROR: could not read openshift-config/pull-secret after 5 attempts" >&2
  set -x
  return 1
}

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
CATALOG_IMAGE="quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v${MINOR_VERSION}"

echo "Installing GitOps Operator from catalog: ${CATALOG_IMAGE}"
echo "OpenShift version: ${OPENSHIFT_VERSION} (minor: ${MINOR_VERSION})"
echo "Target namespace: ${NAMESPACE}"

# 1. Inject quay pull credentials into cluster
#
# Skipped entirely when the cluster already has them. On a hosted (HyperShift) cluster
# it never does, so this runs as before. On a standalone cluster — e.g. one leased from
# a Hive ClusterPool whose install-config already carried these credentials — patching
# openshift-config/pull-secret is node-level configuration, so the Machine Config
# Operator would roll every node: roughly 10-15 minutes on a 6-node cluster, paid on
# every single test run, for no change in content.
#
# The check is on content rather than on cluster topology, so it stays correct for any
# provisioner that pre-loads the credentials.
if [[ -f "/quay-pull-credentials/.dockerconfigjson" ]]; then
  # External control plane means a hosted cluster (HyperShift); Standalone/HighlyAvailable
  # means the control plane runs on the cluster's own nodes.
  CONTROL_PLANE_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}' 2>/dev/null || echo "Unknown")
  echo "Control plane topology: ${CONTROL_PLANE_TOPOLOGY}"

  EXISTING_FILE="$SECRET_DIR/existing.json"
  read_cluster_pull_secret "$EXISTING_FILE"
  PULL_SECRET_UP_TO_DATE=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    existing = json.load(f).get('auths', {})
with open('/quay-pull-credentials/.dockerconfigjson') as f:
    extra = json.load(f).get('auths', {})

def covered(repo):
    # Container runtimes resolve registry auth by longest path prefix, so a credential
    # for quay.io/redhat-user-workloads/rh-openshift-gitops-tenant already grants access
    # to every repository beneath it. Comparing keys exactly reports those children as
    # missing and patches the cluster pull-secret for no reason — which on a standalone
    # cluster rolls every node through the MCO, on every run.
    if repo in existing:
        return True
    parts = repo.split('/')
    return any('/'.join(parts[:i]) in existing for i in range(len(parts) - 1, 0, -1))

missing = [r for r in extra if not covered(r)]
print('no' if missing else 'yes')
if missing:
    print('missing registries: ' + ', '.join(sorted(missing)), file=sys.stderr)
" "$EXISTING_FILE")

  if [[ "$PULL_SECRET_UP_TO_DATE" == "yes" ]]; then
    echo "Cluster pull-secret already carries all required registry credentials — skipping injection."
    echo "(avoids an unnecessary MachineConfig rollout on standalone clusters)"
  else
    # 1a. Patch global pull-secret (may take time to propagate on HyperShift)
    echo "Injecting quay pull credentials into cluster global pull-secret..."
    MERGED_FILE="$SECRET_DIR/merged.json"
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    existing = json.load(f)
with open('/quay-pull-credentials/.dockerconfigjson') as f:
    extra = json.load(f)
existing.setdefault('auths', {}).update(extra.get('auths', {}))
with open(sys.argv[2], 'w') as f:
    json.dump(existing, f)
" "$EXISTING_FILE" "$MERGED_FILE"
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="$MERGED_FILE"
    echo "Injected $(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['auths']))" "$MERGED_FILE" 2>/dev/null) registry credentials into cluster pull-secret"

    if [[ "$CONTROL_PLANE_TOPOLOGY" != "External" ]]; then
      echo "Standalone control plane: the Machine Config Operator will now roll the nodes."
      echo "Consider baking these credentials into the cluster's install-config instead."
    fi
  fi

  # 1b. Create additional-pull-secret in kube-system (HyperShift-native mechanism).
  # The Hosted Cluster Config Operator detects this secret and deploys a DaemonSet
  # that writes credentials to /var/lib/kubelet/config.json on each node.
  #
  # Hosted clusters only. On a standalone cluster nothing reconciles this secret, no
  # syncer DaemonSet is ever created, and the wait below would burn its full 300s
  # timeout before warning and continuing. The MachineConfig rollout from 1a is what
  # delivers credentials to nodes there.
  if [[ "$CONTROL_PLANE_TOPOLOGY" == "External" ]]; then
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
    echo "Standalone control plane — skipping HyperShift additional-pull-secret and syncer wait."
  fi
else
  echo "WARNING: No quay pull credentials found at /quay-pull-credentials/.dockerconfigjson"
fi

# 2. Ensure the operator namespace exists
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

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

# 3b. Record which build the tag actually resolved to.
#
# CATALOG_IMAGE is a tag on purpose -- catalog:v<minor> is what gets promoted as the release,
# so every run should test whatever it points at now rather than a frozen digest. The cost is
# that "we tested v4.22" does not say *what* was tested: the tag moves with each release
# candidate. The digest is recoverable from the catalog pod OLM starts, so record it.
record_catalog_digest() {
  local shared="${SHARED_DIR:-/shared}" digest="" attempt
  for attempt in $(seq 1 30); do
    digest=$(oc get pods -n openshift-marketplace -l olm.catalogSource=gitops-stage \
               -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)
    [[ -n "$digest" ]] && break
    sleep 10
  done
  if [[ -z "$digest" ]]; then
    echo "WARNING: could not resolve the catalog digest -- results will name only ${CATALOG_IMAGE}"
    return 0
  fi
  echo "Catalog under test: ${CATALOG_IMAGE} -> ${digest}"
  mkdir -p "$shared"
  printf '%s\n' "$digest" > "${shared}/catalog-image-digest.txt"
  printf '%s\n' "$CATALOG_IMAGE" > "${shared}/catalog-image-tag.txt"
}
record_catalog_digest

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
  # startingCSV alone does not hold a cluster at that version: with the default Automatic
  # approval OLM installs it and then walks up the channel unattended, which for the 4.22
  # catalog means landing on the newest release before a test can look at the old one. An
  # upgrade test sets HOLD_AT_VERSION so the install stops here and upgrade-operator.sh
  # decides when to move.
  if [[ "${HOLD_AT_VERSION:-false}" == "true" ]]; then
    SUBSCRIPTION_YAML+="
  installPlanApproval: Manual"
  fi
fi

echo "$SUBSCRIPTION_YAML" | oc apply -f -
echo "Subscription created: channel=${OPERATOR_CHANNEL}${OPERATOR_VERSION:+, startingCSV=v${OPERATOR_VERSION}}${HOLD_AT_VERSION:+, approval=Manual}"

# Nothing installs under Manual approval until an InstallPlan is approved, so wait_for_csv
# below would time out on a Subscription that is working exactly as asked.
if [[ "${HOLD_AT_VERSION:-false}" == "true" && -n "${OPERATOR_VERSION:-}" ]]; then
  approve_install_plan "openshift-gitops-operator.v${OPERATOR_VERSION}" "${NAMESPACE}" 600 || exit 1
fi

# 6. Wait for installation
if ! wait_for_csv gitops-operator-konflux "${NAMESPACE}" "${INSTALL_TIMEOUT}"; then
  exit 1
fi

echo "Operator installed successfully (CSV: ${CSV_NAME})"

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
  CLUSTER_SECRET_FILE="$SECRET_DIR/cluster.json"
  read_cluster_pull_secret "$CLUSTER_SECRET_FILE" || true
  MISSING=0
  while IFS= read -r repo; do
    # Match by longest path prefix, the way container runtimes resolve registry auth. A
    # credential for quay.io/redhat-user-workloads/rh-openshift-gitops-tenant already
    # grants access to every repository beneath it, so exact key lookup reports all 21
    # children as missing on a cluster seeded with the parent — which is exactly what a
    # Hive pool cluster looks like. That produced a warning directly contradicting the
    # skip decision made earlier in this same script.
    #
    # $repo is passed as an argument rather than interpolated into the program text, so
    # a repository name containing a quote cannot break the check.
    if python3 -c '
import json, sys
with open(sys.argv[2]) as f:
    auths = json.load(f).get("auths", {})
repo = sys.argv[1]
if repo in auths:
    sys.exit(0)
parts = repo.split("/")
sys.exit(0 if any("/".join(parts[:i]) in auths for i in range(len(parts) - 1, 0, -1)) else 1)
' "$repo" "$CLUSTER_SECRET_FILE" 2>/dev/null; then
      echo "  OK   $repo"
    else
      echo "  MISS $repo"
      MISSING=$((MISSING + 1))
    fi
  done <<< "$EXPECTED_REPOS"
  if [[ $MISSING -gt 0 ]]; then
    echo "WARNING: $MISSING repo(s) missing from cluster pull-secret"
  else
    echo "Pull-secret contains injected credentials"
  fi
fi
