#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT="${SCRIPT_DIR}"
IMAGE_REPO="${IMAGE_REPO:-quay.io/devtools_gitops/test_image}"
BASE_DOCKERFILE="${BASE_DOCKERFILE:-Dockerfile.base-v1.21}"

BUILD_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

BASE_HASH=$(sha256sum "${CONTEXT}/${BASE_DOCKERFILE}" | cut -c1-12)
BASE_IMAGE="${IMAGE_REPO}:base-${BUILD_ARCH}-${BASE_HASH}"

TESTSUITES_HASH=$(cat "${CONTEXT}/${BASE_DOCKERFILE}" "${CONTEXT}/Dockerfile.testsuites" | sha256sum | cut -c1-12)
TESTSUITES_IMAGE="${IMAGE_REPO}:testsuites-${BUILD_ARCH}-${TESTSUITES_HASH}"

SCRIPTS_HASH=$(find "${CONTEXT}/scripts" -type f -exec sha256sum {} \; | sort | sha256sum | cut -c1-12)
FINAL_HASH=$(echo "${TESTSUITES_HASH}${SCRIPTS_HASH}" | sha256sum | cut -c1-12)
FINAL_IMAGE="${IMAGE_REPO}:final-${BUILD_ARCH}-${FINAL_HASH}"

echo "Image repo:  ${IMAGE_REPO}"
echo "Base Dockerfile: ${BASE_DOCKERFILE}"
echo "Architecture: ${BUILD_ARCH}"
echo "Base:         ${BASE_IMAGE}"
echo "Testsuites:   ${TESTSUITES_IMAGE}"
echo "Final:        ${FINAL_IMAGE}"
echo ""

# Layer 1: Base
if skopeo inspect "docker://${BASE_IMAGE}" >/dev/null 2>&1; then
    echo "Base image exists, skipping."
else
    echo "Building base image..."
    podman build \
        --format=oci \
        -f "${CONTEXT}/${BASE_DOCKERFILE}" \
        -t "${BASE_IMAGE}" \
        "${CONTEXT}"
    podman push "${BASE_IMAGE}"
    echo "Pushed: ${BASE_IMAGE}"
fi

# Layer 2: Testsuites
if skopeo inspect "docker://${TESTSUITES_IMAGE}" >/dev/null 2>&1; then
    echo "Testsuites image exists, skipping."
else
    echo "Building testsuites image..."
    podman build \
        --format=oci \
        --build-arg="BASE_IMAGE=${BASE_IMAGE}" \
        -f "${CONTEXT}/Dockerfile.testsuites" \
        -t "${TESTSUITES_IMAGE}" \
        "${CONTEXT}"
    podman push "${TESTSUITES_IMAGE}"
    echo "Pushed: ${TESTSUITES_IMAGE}"
fi

# Layer 3: Final (scripts overlay)
echo "Building final image..."
podman build \
    --format=oci \
    --build-arg="BASE_IMAGE=${TESTSUITES_IMAGE}" \
    -f "${CONTEXT}/Dockerfile" \
    -t "${FINAL_IMAGE}" \
    "${CONTEXT}"
podman push "${FINAL_IMAGE}"
echo ""
echo "Pushed: ${FINAL_IMAGE}"
echo ""
echo "Use this image in pipelines:"
echo "  TEST_IMAGE_URL=${FINAL_IMAGE}"
