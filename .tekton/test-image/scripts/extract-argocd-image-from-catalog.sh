#!/bin/bash
set -euo pipefail

# Extract ArgoCD server image from a catalog by querying the latest bundle.
# This script:
#   1. Queries the catalog using grpc-health-probe
#   2. Finds the latest bundle for openshift-gitops-operator
#   3. Extracts the ArgoCD server image from the bundle's relatedImages
#
# Environment variables expected:
# - CATALOG_IMAGE: Full catalog image reference (e.g., quay.io/.../catalog:v4.14)
# - OPERATOR_CHANNEL: Operator channel to query (default: "latest")
# - OPERATOR_NAME: Operator package name (default: "openshift-gitops-operator")
#
# Outputs:
# - ARGOCD_IMAGE: Full ArgoCD server image reference (written to stdout)

CATALOG_IMAGE="${CATALOG_IMAGE:?CATALOG_IMAGE must be set}"
OPERATOR_CHANNEL="${OPERATOR_CHANNEL:-latest}"
OPERATOR_NAME="${OPERATOR_NAME:-openshift-gitops-operator}"

echo "Extracting ArgoCD image from catalog: ${CATALOG_IMAGE}"
echo "  Channel: ${OPERATOR_CHANNEL}"
echo "  Package: ${OPERATOR_NAME}"

# Start catalog container in background
CATALOG_POD="catalog-query-$$"
echo "Starting catalog container..."
podman run -d --name "$CATALOG_POD" \
  --entrypoint=/bin/opm \
  "$CATALOG_IMAGE" \
  serve /configs >/dev/null

# Wait for catalog to be ready
echo "Waiting for catalog to be ready..."
for i in {1..30}; do
  if podman exec "$CATALOG_POD" grpc-health-probe -addr=:50051 >/dev/null 2>&1; then
    echo "Catalog is ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Catalog failed to become ready"
    podman logs "$CATALOG_POD" 2>&1 || true
    podman rm -f "$CATALOG_POD" >/dev/null 2>&1 || true
    exit 1
  fi
  sleep 2
done

# Query catalog for latest bundle
echo "Querying catalog for latest bundle..."
BUNDLE_IMAGE=$(podman exec "$CATALOG_POD" \
  grpcurl -plaintext localhost:50051 api.Registry/ListBundles \
  | jq -r --arg pkg "$OPERATOR_NAME" --arg ch "$OPERATOR_CHANNEL" \
    'select(.packageName == $pkg and .channelName == $ch) | .csvName + "|" + .bundlePath' \
  | sort -V \
  | tail -1 \
  | cut -d'|' -f2)

podman rm -f "$CATALOG_POD" >/dev/null 2>&1 || true

if [ -z "$BUNDLE_IMAGE" ]; then
  echo "ERROR: Could not find bundle for ${OPERATOR_NAME} in channel ${OPERATOR_CHANNEL}"
  exit 1
fi

echo "Found bundle: ${BUNDLE_IMAGE}"

# Extract bundle manifests
echo "Extracting bundle manifests..."
BUNDLE_DIR=$(mktemp -d)
podman create --name "bundle-extract-$$" "$BUNDLE_IMAGE" >/dev/null
podman export "bundle-extract-$$" | tar -xC "$BUNDLE_DIR" manifests/
podman rm "bundle-extract-$$" >/dev/null 2>&1 || true

# Find CSV and extract ArgoCD server image
CSV_FILE=$(find "$BUNDLE_DIR/manifests" -name "*.clusterserviceversion.yaml" -type f | head -1)
if [ -z "$CSV_FILE" ]; then
  echo "ERROR: Could not find ClusterServiceVersion in bundle"
  rm -rf "$BUNDLE_DIR"
  exit 1
fi

echo "Extracting ArgoCD server image from CSV..."
ARGOCD_IMAGE=$(yq eval '.spec.relatedImages[] | select(.name == "argocd-server" or .name == "argocd" or .image | contains("argocd")) | .image' "$CSV_FILE" \
  | grep -E "argocd.*server|openshift-gitops.*argocd[^-]" \
  | head -1)

rm -rf "$BUNDLE_DIR"

if [ -z "$ARGOCD_IMAGE" ]; then
  echo "ERROR: Could not extract ArgoCD server image from bundle"
  exit 1
fi

echo "Successfully extracted ArgoCD image: ${ARGOCD_IMAGE}"
echo "$ARGOCD_IMAGE"
