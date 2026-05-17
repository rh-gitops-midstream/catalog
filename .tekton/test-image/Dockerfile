ARG BASE_IMAGE=quay.io/devtools_gitops/test_image:testsuites
FROM ${BASE_IMAGE}

LABEL name="gitops-ginkgo-test-runner" \
      description="GitOps integration test runner with helper scripts" \
      maintainer="GitOps Team" \
      io.openshift.tags="gitops,testing,ginkgo,integration"

# Node.js + Playwright for UI E2E tests
ARG NODE_VERSION=v20.18.0
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) NODE_ARCH="x64";; aarch64) NODE_ARCH="arm64";; esac && \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
      | tar -xz -C /usr/local --strip-components=1 && \
    node --version && npm --version

# Copy helper scripts and config files
COPY scripts/ /usr/local/bin/
COPY config/ /usr/local/config/
COPY argocd-v2.14.1-install.yaml /usr/local/argocd-install/argocd-v2.14.1-install.yaml
RUN chmod +x /usr/local/bin/*.sh /usr/local/bin/*.py /usr/local/bin/lib/*.sh

WORKDIR /workspace
ENTRYPOINT ["/bin/bash"]
