#!/bin/bash
set -euo pipefail

# Deploy e2e-test-runner pod in test cluster.
# The pod compiles and runs ArgoCD E2E tests with access to:
# - git-server (via service DNS)
# - ArgoCD (via service DNS)
# - Go toolchain for compiling test binaries

NAMESPACE="${ARGOCD_NAMESPACE:-argocd-e2e}"

# Pod image must be multi-arch (test cluster may be arm64 while pipeline is x86_64)
TEST_RUNNER_IMAGE="${TEST_RUNNER_IMAGE:-registry.access.redhat.com/ubi9/go-toolset:latest}"

echo "Deploying e2e-test-runner pod in namespace ${NAMESPACE}..."
echo "  Image: ${TEST_RUNNER_IMAGE}"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: e2e-test-runner
  namespace: ${NAMESPACE}
  labels:
    app: e2e-test-runner
spec:
  serviceAccountName: default
  containers:
  - name: runner
    image: ${TEST_RUNNER_IMAGE}
    command: ["sleep", "infinity"]
    volumeMounts:
    - name: workspace
      mountPath: /opt/e2e-test
    - name: bin
      mountPath: /tmp/bin
    workingDir: /tmp
    resources:
      requests:
        cpu: "500m"
        memory: "512Mi"
      limits:
        memory: "4Gi"
    securityContext:
      runAsUser: 0
  volumes:
  - name: workspace
    emptyDir: {}
  - name: bin
    emptyDir: {}
  restartPolicy: Never
EOF

echo "Waiting for e2e-test-runner pod to be ready..."
oc wait --for=condition=Ready pod/e2e-test-runner -n "${NAMESPACE}" --timeout=300s

echo "Installing missing packages..."
oc exec -n "${NAMESPACE}" e2e-test-runner -- bash -c '
  PKGS=""
  command -v git >/dev/null 2>&1 || PKGS="$PKGS git"
  command -v gpg >/dev/null 2>&1 || PKGS="$PKGS gnupg2"
  command -v make >/dev/null 2>&1 || PKGS="$PKGS make"
  if [[ -n "$PKGS" ]]; then
    echo "  Installing: $PKGS"
    dnf install -y $PKGS >/dev/null 2>&1
  else
    echo "  All required packages already installed"
  fi

  # Install kubectl if not available (needed by ArgoCD E2E test framework)
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "  Installing kubectl..."
    ARCH=$(uname -m)
    case "${ARCH}" in
      x86_64) ARCH="amd64" ;;
      aarch64) ARCH="arm64" ;;
    esac
    curl -sLo /tmp/bin/kubectl "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
    chmod +x /tmp/bin/kubectl
    echo "  kubectl installed at /tmp/bin/kubectl"
  fi

  # Install helm if not available (needed by Helm E2E tests)
  if ! command -v helm >/dev/null 2>&1; then
    echo "  Installing helm..."
    curl -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR=/tmp/bin bash
    echo "  helm installed at /tmp/bin/helm"
  fi

  # Install kustomize if not available (needed by local sync and diffing tests)
  if ! command -v kustomize >/dev/null 2>&1; then
    echo "  Installing kustomize..."
    ARCH=$(uname -m)
    case "${ARCH}" in
      x86_64) ARCH="amd64" ;;
      aarch64) ARCH="arm64" ;;
    esac
    curl -sLo /tmp/kustomize.tar.gz "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.6.0/kustomize_v5.6.0_linux_${ARCH}.tar.gz"
    tar -xzf /tmp/kustomize.tar.gz -C /tmp/bin kustomize
    rm /tmp/kustomize.tar.gz
    chmod +x /tmp/bin/kustomize
    echo "  kustomize installed at /tmp/bin/kustomize"
  fi
'

echo "e2e-test-runner pod is ready"
oc get pod e2e-test-runner -n "${NAMESPACE}" -o wide
