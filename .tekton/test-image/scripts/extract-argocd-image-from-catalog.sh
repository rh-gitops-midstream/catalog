#!/bin/bash
set -euo pipefail

# Extract ArgoCD server image from a catalog by parsing FBC catalog contents.
# This script:
#   1. Extracts the catalog configs using oc/skopeo
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

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Extract catalog configs directory
echo "Extracting catalog configs..."
CATALOG_DIR="${WORK_DIR}/catalog"
mkdir -p "$CATALOG_DIR"

# Try oc image extract first (faster), fall back to skopeo
if oc image extract "$CATALOG_IMAGE" --path /configs:"${CATALOG_DIR}" 2>/dev/null; then
    echo "Extracted catalog configs using oc image extract"
elif skopeo copy "docker://${CATALOG_IMAGE}" "dir:${WORK_DIR}/catalog-temp" 2>/dev/null; then
    echo "Downloaded catalog image using skopeo"
    # Extract the layer containing /configs
    # The catalog image typically has configs in the last layer
    LAYER_TAR=$(find "${WORK_DIR}/catalog-temp" -name "*.tar" | tail -1)
    if [ -n "$LAYER_TAR" ]; then
        tar -xf "$LAYER_TAR" -C "$CATALOG_DIR" configs/ 2>/dev/null || true
    fi
    # Move configs up if they're nested
    if [ -d "${CATALOG_DIR}/configs" ]; then
        mv "${CATALOG_DIR}/configs"/* "$CATALOG_DIR/" || true
        rmdir "${CATALOG_DIR}/configs" || true
    fi
else
    echo "ERROR: Failed to extract catalog image"
    exit 1
fi

echo "Catalog configs extracted to: ${CATALOG_DIR}"
ls -la "$CATALOG_DIR"

# Find the catalog index JSON (FBC format)
# Look for catalog.json or index.json or any .json file
CATALOG_JSON=$(find "$CATALOG_DIR" -name "*.json" -type f | head -1)
if [ -z "$CATALOG_JSON" ]; then
    echo "ERROR: No JSON catalog file found in configs"
    find "$CATALOG_DIR" -type f
    exit 1
fi

echo "Found catalog JSON: ${CATALOG_JSON}"

# Parse FBC catalog to find the latest bundle
echo "Parsing catalog for package: ${OPERATOR_NAME}, channel: ${OPERATOR_CHANNEL}"

# FBC format has entries like:
# {"schema":"olm.bundle","name":"...", "package":"...", "image":"...", "properties":[...]}
# {"schema":"olm.channel","package":"...","name":"...","entries":[...]}

# First find the channel entry for our package
CHANNEL_ENTRY=$(jq -r --arg pkg "$OPERATOR_NAME" --arg ch "$OPERATOR_CHANNEL" \
    'select(.schema == "olm.channel" and .package == $pkg and .name == $ch)' \
    "$CATALOG_JSON" | head -1)

if [ -z "$CHANNEL_ENTRY" ]; then
    echo "ERROR: Channel ${OPERATOR_CHANNEL} not found for package ${OPERATOR_NAME}"
    echo "Available channels:"
    jq -r --arg pkg "$OPERATOR_NAME" \
        'select(.schema == "olm.channel" and .package == $pkg) | .name' \
        "$CATALOG_JSON" || true
    exit 1
fi

# Get the head of the channel (latest version)
BUNDLE_NAME=$(echo "$CHANNEL_ENTRY" | jq -r '.entries[-1].name // .entries[0].name')

if [ -z "$BUNDLE_NAME" ] || [ "$BUNDLE_NAME" = "null" ]; then
    echo "ERROR: Could not find bundle in channel"
    exit 1
fi

echo "Found latest bundle: ${BUNDLE_NAME}"

# Find the bundle entry to get its image
BUNDLE_IMAGE=$(jq -r --arg name "$BUNDLE_NAME" \
    'select(.schema == "olm.bundle" and .name == $name) | .image' \
    "$CATALOG_JSON")

if [ -z "$BUNDLE_IMAGE" ] || [ "$BUNDLE_IMAGE" = "null" ]; then
    echo "ERROR: Could not find bundle image for ${BUNDLE_NAME}"
    exit 1
fi

echo "Found bundle image: ${BUNDLE_IMAGE}"

# Extract bundle manifests
echo "Extracting bundle manifests..."
BUNDLE_DIR="${WORK_DIR}/bundle"
mkdir -p "$BUNDLE_DIR"

if oc image extract "$BUNDLE_IMAGE" --path /manifests:"${BUNDLE_DIR}" 2>/dev/null; then
    echo "Extracted bundle manifests using oc image extract"
elif skopeo copy "docker://${BUNDLE_IMAGE}" "dir:${WORK_DIR}/bundle-temp" 2>/dev/null; then
    echo "Downloaded bundle image using skopeo"
    LAYER_TAR=$(find "${WORK_DIR}/bundle-temp" -name "*.tar" | tail -1)
    if [ -n "$LAYER_TAR" ]; then
        tar -xf "$LAYER_TAR" -C "$BUNDLE_DIR" manifests/ 2>/dev/null || true
    fi
    if [ -d "${BUNDLE_DIR}/manifests" ]; then
        mv "${BUNDLE_DIR}/manifests"/* "$BUNDLE_DIR/" || true
        rmdir "${BUNDLE_DIR}/manifests" || true
    fi
else
    echo "ERROR: Failed to extract bundle image"
    exit 1
fi

# Find CSV file
CSV_FILE=$(find "$BUNDLE_DIR" -name "*.clusterserviceversion.yaml" -type f | head -1)
if [ -z "$CSV_FILE" ]; then
    echo "ERROR: Could not find ClusterServiceVersion in bundle"
    find "$BUNDLE_DIR" -type f
    exit 1
fi

echo "Found CSV: ${CSV_FILE}"

# Extract ArgoCD server image from relatedImages
echo "Extracting ArgoCD server image from CSV..."

# Try to find argocd-server or argocd image name
ARGOCD_IMAGE=$(yq eval '.spec.relatedImages[] | select(.name == "argocd-server" or .name == "argocd") | .image' "$CSV_FILE" | head -1)

# If not found by exact name, look for argocd in image path (but exclude agent, extensions, etc.)
if [ -z "$ARGOCD_IMAGE" ]; then
    ARGOCD_IMAGE=$(yq eval '.spec.relatedImages[] | select(.image | contains("argocd-rhel")) | select(.image | contains("agent") | not) | select(.image | contains("extension") | not) | .image' "$CSV_FILE" | head -1)
fi

# Last fallback: look for any argocd image that's not agent/extension/rollouts
if [ -z "$ARGOCD_IMAGE" ]; then
    ARGOCD_IMAGE=$(yq eval '.spec.relatedImages[] | select(.name | contains("argocd")) | select(.name | contains("agent") | not) | select(.name | contains("extension") | not) | select(.name | contains("rollouts") | not) | .image' "$CSV_FILE" | head -1)
fi

if [ -z "$ARGOCD_IMAGE" ]; then
    echo "ERROR: Could not extract ArgoCD server image from bundle"
    echo "Related images in CSV:"
    yq eval '.spec.relatedImages[] | .name + ": " + .image' "$CSV_FILE"
    exit 1
fi

echo "Successfully extracted ArgoCD image: ${ARGOCD_IMAGE}"
echo "$ARGOCD_IMAGE"
