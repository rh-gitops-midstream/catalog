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

# Setup registry authentication for pulling from registry.redhat.io
# The pull secret is mounted at /quay-pull-credentials/.dockerconfigjson
if [ -f /quay-pull-credentials/.dockerconfigjson ]; then
    echo "Configuring registry authentication..."
    AUTH_DIR=$(mktemp -d)
    cp /quay-pull-credentials/.dockerconfigjson "${AUTH_DIR}/config.json"
    export DOCKER_CONFIG="${AUTH_DIR}"
    echo "Registry authentication configured (DOCKER_CONFIG=${DOCKER_CONFIG})"

    # Debug: check if registry.redhat.io is in the auth config
    if grep -q "registry.redhat.io" /quay-pull-credentials/.dockerconfigjson; then
        echo "  ✓ Found registry.redhat.io credentials in pull secret"
    else
        echo "  ✗ WARNING: registry.redhat.io NOT found in pull secret"
        echo "  Available registries:"
        jq -r '.auths | keys[]' /quay-pull-credentials/.dockerconfigjson 2>/dev/null || echo "    (unable to parse)"
    fi
else
    echo "WARNING: Pull credentials not found at /quay-pull-credentials/.dockerconfigjson"
    echo "Bundle extraction from registry.redhat.io may fail"
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Extract catalog.json file directly from the catalog image
# The catalog structure is /configs/<operator-name>/catalog.json
echo "Extracting catalog.json..."
EXTRACT_DIR="${WORK_DIR}/extract"
mkdir -p "$EXTRACT_DIR"

CATALOG_JSON="${EXTRACT_DIR}/catalog.json"

# Extract the specific catalog.json file
if ! oc image extract "$CATALOG_IMAGE" \
    --path "/configs/${OPERATOR_NAME}/catalog.json:${EXTRACT_DIR}" 2>&1; then
    echo "ERROR: Failed to extract catalog.json from ${CATALOG_IMAGE}"
    echo "Expected path: /configs/${OPERATOR_NAME}/catalog.json"
    exit 1
fi

# Verify the file exists and is not empty
if [ ! -f "$CATALOG_JSON" ] || [ ! -s "$CATALOG_JSON" ]; then
    echo "ERROR: catalog.json not found or is empty"
    ls -la "$EXTRACT_DIR"
    exit 1
fi

echo "Successfully extracted catalog.json ($(stat -f%z "$CATALOG_JSON" 2>/dev/null || stat -c%s "$CATALOG_JSON") bytes)"

# Parse FBC catalog to find the latest bundle
echo "Parsing catalog for package: ${OPERATOR_NAME}, channel: ${OPERATOR_CHANNEL}"

# FBC format has entries like:
# {"schema":"olm.bundle","name":"...", "package":"...", "image":"...", "properties":[...]}
# {"schema":"olm.channel","package":"...","name":"...","entries":[...]}

# First find the channel entry for our package
# Compact the JSON first to make grep work, then filter
echo "Finding channel entry..."
CHANNEL_ENTRY=$(jq -c --arg pkg "$OPERATOR_NAME" --arg ch "$OPERATOR_CHANNEL" \
    'select(.schema == "olm.channel" and .package == $pkg and .name == $ch)' \
    "$CATALOG_JSON" | head -1)
echo "Channel entry found"

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

echo "Found bundle image from catalog: ${BUNDLE_IMAGE}"

# Map registry.redhat.io bundle to Quay equivalent
# The catalog references registry.redhat.io, but in Konflux we build to Quay
if [[ "$BUNDLE_IMAGE" == registry.redhat.io/* ]]; then
    echo "Remapping bundle from registry.redhat.io to Quay..."

    # Extract version from bundle name (e.g., openshift-gitops-operator.v1.20.2 -> v1.20.2)
    BUNDLE_VERSION=$(echo "$BUNDLE_NAME" | sed -n 's/.*\.\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')

    if [ -z "$BUNDLE_VERSION" ]; then
        echo "WARNING: Could not extract version from bundle name: ${BUNDLE_NAME}"
        echo "Using bundle name as tag"
        BUNDLE_VERSION="$BUNDLE_NAME"
    fi

    # Construct Quay bundle URL
    QUAY_BUNDLE="quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-operator-bundle:${BUNDLE_VERSION}"
    echo "  Original: ${BUNDLE_IMAGE}"
    echo "  Remapped: ${QUAY_BUNDLE}"
    BUNDLE_IMAGE="$QUAY_BUNDLE"
else
    echo "Bundle image already uses Quay or other accessible registry"
fi

# Extract bundle manifests
echo "Extracting bundle manifests from: ${BUNDLE_IMAGE}"
BUNDLE_EXTRACT="${WORK_DIR}/bundle-extract"
mkdir -p "$BUNDLE_EXTRACT"

if oc image extract "$BUNDLE_IMAGE" --path /manifests:"${BUNDLE_EXTRACT}" 2>&1; then
    echo "Extracted bundle manifests using oc image extract"
else
    echo "ERROR: Failed to extract bundle manifests from ${BUNDLE_IMAGE}"
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
