#!/bin/bash
set -uo pipefail

# Collects component versions from a running GitOps operator cluster.
# Usage: collect-build-metadata.sh [output-json-path]
# Requires: KUBECONFIG set, cluster reachable, oc available

OUTPUT="${1:-/shared/build-metadata.json}"
NS="openshift-gitops"
OP_NS="openshift-gitops-operator"

find_pod() {
  local prefix="$1"
  oc get pods -n "$NS" --field-selector=status.phase=Running -o name 2>/dev/null \
    | grep "/${prefix}" \
    | head -1 \
    | sed 's|^pod/||'
}

echo "Collecting build metadata from cluster..."

BUILD=$(oc get csv -n "$OP_NS" -o jsonpath='{.items[0].spec.version}' 2>/dev/null || echo "")

SERVER_POD=$(find_pod "openshift-gitops-server")
DEX_POD=$(find_pod "openshift-gitops-dex-server")
REDIS_POD=$(find_pod "openshift-gitops-redis")

ARGOCD=""
KUSTOMIZE=""
HELM=""
GIT_LFS=""
DEX=""
REDIS=""
AGENT=""

if [ -n "$SERVER_POD" ]; then
  echo "  Server pod: $SERVER_POD"
  ARGOCD=$(oc exec -n "$NS" "$SERVER_POD" -- argocd version --client --short 2>/dev/null | sed 's/argocd: //' || true)
  KUSTOMIZE=$(oc exec -n "$NS" "$SERVER_POD" -- kustomize version 2>/dev/null | tr -d '[:space:]' || true)
  HELM=$(oc exec -n "$NS" "$SERVER_POD" -- helm version --short 2>/dev/null | sed 's/+.*//' || true)
  GIT_LFS=$(oc exec -n "$NS" "$SERVER_POD" -- git-lfs version 2>/dev/null | grep -oP 'git-lfs/\K[^ ]+' || true)
else
  echo "  WARNING: No running openshift-gitops-server pod found"
fi

if [ -n "$DEX_POD" ]; then
  echo "  Dex pod: $DEX_POD"
  DEX=$(oc exec -n "$NS" "$DEX_POD" -- dex version 2>/dev/null | grep 'Dex Version:' | sed 's/.*: //' | tr -d '[:space:]' || true)
else
  echo "  WARNING: No running dex pod found"
fi

if [ -n "$REDIS_POD" ]; then
  echo "  Redis pod: $REDIS_POD"
  REDIS=$(oc exec -n "$NS" "$REDIS_POD" -- redis-server -v 2>/dev/null | grep -oP 'v=\K[^ ]+' || true)
else
  echo "  WARNING: No running redis pod found"
fi

AGENT_IMAGE=$(oc get deployment -n "$NS" -l app.kubernetes.io/component=agent-principal \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [ -n "$AGENT_IMAGE" ]; then
  AGENT=$(echo "$AGENT_IMAGE" | grep -oP ':\K.*' || true)
fi

python3 -c "
import json
data = {
    'build': '''${BUILD}''',
    'argocd': '''${ARGOCD}''',
    'dex': '''${DEX}''',
    'redis': '''${REDIS}''',
    'kustomize': '''${KUSTOMIZE}''',
    'helm': '''${HELM}''',
    'gitLfs': '''${GIT_LFS}''',
    'agent': '''${AGENT}''',
}
data = {k: v for k, v in data.items() if v}
with open('''${OUTPUT}''', 'w') as f:
    json.dump(data, f, indent=2)
print('Build metadata:', json.dumps(data, separators=(', ', ': ')))
"
