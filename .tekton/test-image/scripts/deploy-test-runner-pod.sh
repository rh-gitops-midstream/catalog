#!/bin/bash
set -euo pipefail

# Deploy e2e-test-runner pod in test cluster
# This pod will execute the ArgoCD E2E tests with access to:
# - git-server (via service DNS)
# - ArgoCD (via service DNS)
# - Local filesystem for git operations

NAMESPACE="${ARGOCD_NAMESPACE:-argocd-e2e}"

echo "Deploying e2e-test-runner pod in namespace ${NAMESPACE}..."

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
    image: registry.access.redhat.com/ubi9/ubi:latest
    command: ["sleep", "infinity"]
    volumeMounts:
    - name: workspace
      mountPath: /tmp/argo-e2e
    - name: bin
      mountPath: /tmp/bin
    workingDir: /tmp/argo-e2e
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
oc wait --for=condition=Ready pod/e2e-test-runner -n "${NAMESPACE}" --timeout=120s

echo "Installing git in e2e-test-runner pod..."
oc exec -n "${NAMESPACE}" e2e-test-runner -- dnf install -y git >/dev/null 2>&1

echo "e2e-test-runner pod is ready"
oc get pod e2e-test-runner -n "${NAMESPACE}" -o wide
