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
EXTRACT_DIR="${WORK_DIR}/extract"
mkdir -p "$EXTRACT_DIR"

# Extract entire image to get /configs directory
if oc image extract "$CATALOG_IMAGE" --path /:"${EXTRACT_DIR}" 2>/dev/null; then
    echo "Extracted catalog image using oc image extract"
elif skopeo copy "docker://${CATALOG_IMAGE}" "dir:${WORK_DIR}/catalog-temp" 2>/dev/null; then
    echo "Downloaded catalog image using skopeo"
    # Extract the layer containing /configs (typically the last non-base layer)
    for layer in $(find "${WORK_DIR}/catalog-temp" -name "*.tar" | sort); do
        tar -xf "$layer" -C "$EXTRACT_DIR" configs/ 2>/dev/null && break || true
    done
else
    echo "ERROR: Failed to extract catalog image"
    exit 1
fi

# Check if we got the configs directory
if [ ! -d "${EXTRACT_DIR}/configs" ]; then
    echo "ERROR: /configs directory not found in catalog image"
    echo "Extracted contents:"
    ls -la "$EXTRACT_DIR"
    exit 1
fi

echo "Catalog configs extracted successfully"
find "${EXTRACT_DIR}/configs" -type f -name "*.json" | head -5

# Find the catalog index JSON (FBC format)
# Look for catalog.json specifically (FBC catalogs use this name)
CATALOG_JSON=$(find "${EXTRACT_DIR}/configs" -name "catalog.json" -type f | head -1)

# If not found, try index.json or any .json that's not in buildinfo
if [ -z "$CATALOG_JSON" ]; then
    CATALOG_JSON=$(find "${EXTRACT_DIR}/configs" -name "index.json" -type f | head -1)
fi

if [ -z "$CATALOG_JSON" ]; then
    CATALOG_JSON=$(find "${EXTRACT_DIR}/configs" -name "*.json" -type f ! -path "*/buildinfo/*" | head -1)
fi

if [ -z "$CATALOG_JSON" ]; then
    echo "ERROR: No JSON catalog file found in configs"
    echo "Directory structure:"
    find "${EXTRACT_DIR}/configs" -type f
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
BUNDLE_EXTRACT="${WORK_DIR}/bundle-extract"
mkdir -p "$BUNDLE_EXTRACT"

if oc image extract "$BUNDLE_IMAGE" --path /:"${BUNDLE_EXTRACT}" 2>/dev/null; then
    echo "Extracted bundle image using oc image extract"
elif skopeo copy "docker://${BUNDLE_IMAGE}" "dir:${WORK_DIR}/bundle-temp" 2>/dev/null; then
    echo "Downloaded bundle image using skopeo"
    # Extract the layer containing /manifests
    for layer in $(find "${WORK_DIR}/bundle-temp" -name "*.tar" | sort); do
        tar -xf "$layer" -C "$BUNDLE_EXTRACT" manifests/ 2>/dev/null && break || true
    done
else
    echo "ERROR: Failed to extract bundle image"
    exit 1
fi

# Check if we got the manifests directory
if [ ! -d "${BUNDLE_EXTRACT}/manifests" ]; then
    echo "ERROR: /manifests directory not found in bundle image"
    echo "Extracted contents:"
    ls -la "$BUNDLE_EXTRACT"
    exit 1
fi

# Find CSV file
CSV_FILE=$(find "${BUNDLE_EXTRACT}/manifests" -name "*.clusterserviceversion.yaml" -type f | head -1)
if [ -z "$CSV_FILE" ]; then
    echo "ERROR: Could not find ClusterServiceVersion in bundle"
    find "${BUNDLE_EXTRACT}/manifests" -type f
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
