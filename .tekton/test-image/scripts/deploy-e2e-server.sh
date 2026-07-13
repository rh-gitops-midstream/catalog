#!/bin/bash
set -euo pipefail

# Deploy the upstream ArgoCD E2E test server (argocd-e2e-server).
# Provides git repos over HTTP, HTTPS (basic auth), HTTPS (client cert),
# SSH, and Helm chart repos — matching upstream test/remote infrastructure.

NAMESPACE="${ARGOCD_NAMESPACE:-argocd-e2e}"
E2E_SERVER_IMAGE="${E2E_SERVER_IMAGE:-quay.io/redhat-developer/argocd-e2e-cluster:latest}"

echo "Deploying argocd-e2e-server in namespace ${NAMESPACE}..."
echo "  Image: ${E2E_SERVER_IMAGE}"

cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-e2e-cluster
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: argocd-e2e-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-e2e-server
  template:
    metadata:
      labels:
        app.kubernetes.io/name: argocd-e2e-server
    spec:
      serviceAccountName: default
      containers:
      - name: argocd-e2e-server
        image: ${E2E_SERVER_IMAGE}
        imagePullPolicy: Always
        command:
        - goreman
        - start
        ports:
        - containerPort: 2222
          name: git-ssh
        - containerPort: 9080
          name: helm-https
        - containerPort: 9081
          name: git-http-noauth
        - containerPort: 9443
          name: git-https-auth
        - containerPort: 9444
          name: git-https-ccert
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            memory: "512Mi"
        securityContext:
          capabilities:
            add: ["SYS_CHROOT"]
---
apiVersion: v1
kind: Service
metadata:
  name: argocd-e2e-server
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: argocd-e2e-server
spec:
  selector:
    app.kubernetes.io/name: argocd-e2e-server
  ports:
  - name: helm-https
    protocol: TCP
    port: 9080
    targetPort: 9080
  - name: git-http-noauth
    protocol: TCP
    port: 9081
    targetPort: 9081
  - name: git-https-auth
    protocol: TCP
    port: 9443
    targetPort: 9443
  - name: git-https-ccert
    protocol: TCP
    port: 9444
    targetPort: 9444
  - name: git-ssh
    protocol: TCP
    port: 2222
    targetPort: 2222
EOF

echo "Waiting for argocd-e2e-server deployment to roll out..."
oc rollout status deployment/argocd-e2e-cluster -n "${NAMESPACE}" --timeout=120s

echo "argocd-e2e-server is ready"
oc get deployment argocd-e2e-cluster -n "${NAMESPACE}"
oc get service argocd-e2e-server -n "${NAMESPACE}"
