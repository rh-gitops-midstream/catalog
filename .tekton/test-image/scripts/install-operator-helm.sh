#!/bin/bash
# Install the GitOps operator on a non-OpenShift cluster from a rendered Helm chart.
#
# The OLM counterpart is install-operator.sh. Here there is no CatalogSource or
# Subscription: the chart has already been rendered (by `helm template`, in a step that has
# helm) into MANIFEST, and this applies it and waits for the operator to come up.
#
# No `set -x`: MANIFEST carries the registry pull secret, and nothing here should echo it.
#
# Environment:
#   KUBECONFIG       cluster to install on
#   MANIFEST         rendered chart, including CRDs
#   NAMESPACE        operator namespace (default openshift-gitops-operator)
#   INSTALL_TIMEOUT  how long to wait for the operator (default 10m)
set -euo pipefail

NAMESPACE="${NAMESPACE:-openshift-gitops-operator}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-10m}"
: "${MANIFEST:?MANIFEST must point at the rendered chart}"
[[ -s "$MANIFEST" ]] || { echo "ERROR: $MANIFEST is empty or missing"; exit 1; }

DEPLOYMENT=openshift-gitops-operator-controller-manager

echo "Installing the GitOps operator from a Helm chart into ${NAMESPACE}"
echo "  server: $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
echo "  objects: $(grep -c '^kind:' "$MANIFEST")"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Server-side, as the chart's own instructions do: the Argo CD CRDs exceed the
# 262144-byte last-applied annotation a client-side apply would write.
# CRDs first, and established, so the custom resources in the same manifest do not race
# their definitions.
CRDS=$(mktemp); REST=$(mktemp)
trap 'rm -f "$CRDS" "$REST"' EXIT
python3 - "$MANIFEST" "$CRDS" "$REST" <<'PY'
import sys, yaml
src, crds, rest = sys.argv[1:]
# Anything without a kind is not a manifest — e.g. the "Pulled:"/"Digest:" lines
# `helm template oci://...` prints to stdout. Report it rather than fail the apply on it.
docs = []
for d in yaml.safe_load_all(open(src)):
    if isinstance(d, dict) and d.get("kind") and d.get("apiVersion"):
        docs.append(d)
    elif d:
        print(f"ignoring a non-manifest document: {sorted(d) if isinstance(d, dict) else type(d).__name__}")
with open(crds, "w") as c, open(rest, "w") as r:
    yaml.safe_dump_all([d for d in docs if d.get("kind") == "CustomResourceDefinition"], c)
    yaml.safe_dump_all([d for d in docs if d.get("kind") != "CustomResourceDefinition"], r)
PY
echo "Applying CRDs..."
kubectl apply --server-side --force-conflicts -f "$CRDS" >/dev/null
kubectl wait --for=condition=Established crd --all --timeout=2m >/dev/null
echo "Applying operator resources..."
kubectl apply --server-side --force-conflicts -n "$NAMESPACE" -f "$REST" \
  | sed -E 's/^(secret\/[^ ]+) .*/\1 (applied)/'

echo "Waiting up to ${INSTALL_TIMEOUT} for deployment/${DEPLOYMENT}..."
if ! kubectl rollout status "deployment/${DEPLOYMENT}" -n "$NAMESPACE" --timeout="$INSTALL_TIMEOUT"; then
  echo "ERROR: the operator did not become ready"
  kubectl get pods -n "$NAMESPACE" -o wide || true
  kubectl describe "deployment/${DEPLOYMENT}" -n "$NAMESPACE" | tail -30 || true
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -20 || true
  exit 1
fi

IMAGE=$(kubectl get "deployment/${DEPLOYMENT}" -n "$NAMESPACE" \
          -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "Operator running: ${IMAGE}"
kubectl get pods -n "$NAMESPACE" -o wide
