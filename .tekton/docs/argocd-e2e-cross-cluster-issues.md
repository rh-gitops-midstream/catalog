# ArgoCD E2E Cross-Cluster Execution Issues

## Problem Summary

The ArgoCD E2E test suite has deep assumptions about co-location with ArgoCD and the git-server. Our current approach (running tests in Konflux cluster while ArgoCD/git-server are in the ephemeral test cluster) **cannot work** without major architectural changes.

## Test Co-Location Assumptions

### 1. Local Git Repository Operations

**What tests expect:** (from `test/e2e/fixture/fixture.go`)

```go
// Tests copy fixtures to local directory
_, err = Run("", "cp", "-Rf", "testdata", "/tmp/argo-e2e/testdata.git")

// Tests initialize git repo locally
_, err = Run("/tmp/argo-e2e/testdata.git", "git", "init", "-b", "master")
_, err = Run("/tmp/argo-e2e/testdata.git", "git", "add", ".")
_, err = Run("/tmp/argo-e2e/testdata.git", "git", "commit", "-q", "-m", "initial commit")

// Tests push to remote git-server
_, err = Run("/tmp/argo-e2e/testdata.git", "git", "remote", "add", "origin", 
             os.Getenv("ARGOCD_E2E_GIT_SERVICE"))
_, err = Run("/tmp/argo-e2e/testdata.git", "git", "push", "origin", "master", "-f")
```

**Required filesystem layout:**
```
/tmp/argo-e2e/
├── testdata.git/          # Working git repo (writable, tests commit/push here)
├── submodule.git/         # Submodule tests
└── submoduleParent.git/   # Submodule parent tests

test/e2e/testdata/         # Source fixtures (read-only, 79 subdirectories)
```

**What tests do with the local git repo:**
- Copy fixture directories from `test/e2e/testdata/{fixture-name}` to `/tmp/argo-e2e/testdata.git/`
- Initialize as git repository
- Commit initial state
- Push to remote git-server (`git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git`)
- During tests: modify files, commit, push to trigger ArgoCD sync
- Read files back to assert changes were applied

### 2. Git Server Connectivity

**Current git-server deployment:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: git-server
  namespace: argocd-e2e  # In test cluster
spec:
  containers:
  - name: git-server
    image: bitnami/git:latest
    command: ["git", "daemon", "--base-path=/git", "--export-all", "--port=9418"]
---
apiVersion: v1
kind: Service
metadata:
  name: git-server
  namespace: argocd-e2e  # In test cluster
spec:
  ports:
    - port: 9418      # Git protocol (not HTTP/HTTPS)
      targetPort: 9418
```

**Git protocol (port 9418) limitations:**
- Not HTTP-based, cannot use OpenShift Routes
- Service-only (no Ingress/Route support)
- Requires direct network access to pod
- Port-forward is unreliable for git push operations

**Tests expect:**
```bash
ARGOCD_E2E_GIT_SERVICE=git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git
```

This DNS name only resolves **inside the test cluster**, not from Konflux cluster.

### 3. File-Based Test Assertions

**Tests directly read/write local files:**
```go
// Write file to test repo
CheckError(os.WriteFile(filepath.Join(repoDirectory(), path), []byte(contents), 0o644))

// Commit and push
FailOnErr(Run(repoDirectory(), "git", "add", "."))
FailOnErr(Run(repoDirectory(), "git", "commit", "-am", "add file"))
FailOnErr(Run(repoDirectory(), "git", "push", "-f", "origin", "master"))

// Delete file
CheckError(os.Remove(filepath.Join(repoDirectory(), path)))
FailOnErr(Run(repoDirectory(), "git", "commit", "-am", "delete"))

// Patch file
filename := filepath.Join(repoDirectory(), path)
CheckError(os.WriteFile(filename, bytes, 0o644))
FailOnErr(Run(repoDirectory(), "git", "commit", "-am", "patch"))
```

Tests cannot operate on files remotely via `oc exec` - the test binary itself needs local filesystem access.

## Why Our Current Approach Fails

### Current Architecture
```
┌─────────────────────────┐
│   Konflux Cluster       │
│                         │
│  ┌──────────────────┐   │
│  │ Test Pod         │   │──┐
│  │ (run-argocd-e2e) │   │  │ Try to connect to git-server
│  │                  │   │  │ git://git-server.argocd-e2e.svc...
│  │ Needs:           │   │  │ ❌ DNS fails (cross-cluster)
│  │ - /tmp/argo-e2e/ │   │  │
│  │ - test/e2e/      │   │  │
│  │   testdata/      │   │  │
│  └──────────────────┘   │  │
└─────────────────────────┘  │
                             │
┌─────────────────────────┐  │
│  Test Cluster           │  │
│  (Ephemeral Hypershift) │  │
│                         │  │
│  ┌──────────────────┐   │  │
│  │ ArgoCD           │   │◄─┼─ Exposed via Route (HTTPS)
│  │  argocd-e2e      │   │  │  ✓ Works
│  └──────────────────┘   │  │
│                         │  │
│  ┌──────────────────┐   │  │
│  │ git-server       │   │◄─┘
│  │  Service only    │   │    ❌ Not accessible cross-cluster
│  │  port 9418       │   │    ❌ Git protocol, no Route support
│  └──────────────────┘   │
└─────────────────────────┘
```

**Problems:**
1. **DNS resolution fails:** `git-server.argocd-e2e.svc.cluster.local` doesn't resolve from Konflux cluster
2. **No Route for git protocol:** Port 9418 git daemon cannot be exposed via OpenShift Route (Routes only support HTTP/HTTPS)
3. **Port-forward won't work:** `oc port-forward` is unreliable for git push operations and requires keeping connection alive during test execution
4. **Fixture access:** Test pod doesn't have access to `test/e2e/testdata/` directory (not copied into test image)

## Solution: Run Tests Inside Test Cluster

### Downstream-CI Proven Pattern

Downstream-CI runs tests **inside a pod in the test cluster**, not remotely:

```
┌─────────────────────────┐
│   Konflux Cluster       │
│                         │
│  ┌──────────────────┐   │
│  │ Tekton Task      │   │── oc exec ──┐
│  │ (orchestration)  │   │             │
│  └──────────────────┘   │             │
└─────────────────────────┘             │
                                        │
┌─────────────────────────┐             │
│  Test Cluster           │             │
│  (Ephemeral Hypershift) │             │
│                         │             │
│  ┌──────────────────┐   │             │
│  │ ArgoCD           │   │◄────────────┼─ Tests access via
│  │  argocd-e2e      │   │             │  Service DNS ✓
│  └──────────────────┘   │             │
│                         │             │
│  ┌──────────────────┐   │             │
│  │ git-server       │   │◄────────────┼─ Tests push via
│  │  port 9418       │   │             │  Service DNS ✓
│  └──────────────────┘   │             │
│                         │             │
│  ┌──────────────────┐   │             │
│  │ e2e-test-runner  │   │◄────────────┘
│  │                  │   │  oc exec ... sh /tmp/run_test.sh
│  │ Has:             │   │
│  │ - e2e.test       │   │  (copied via oc cp)
│  │ - testdata/      │   │  (copied via oc cp)
│  │ - argocd CLI     │   │  (copied via oc cp)
│  │ - /tmp/argo-e2e/ │   │  (writable emptyDir)
│  └──────────────────┘   │
└─────────────────────────┘
```

## Required Changes

### 1. Create e2e-test-runner Pod

**New script:** `.tekton/test-image/scripts/deploy-test-runner-pod.sh`

```bash
#!/bin/bash
# Deploy e2e-test-runner pod in test cluster with all dependencies

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: e2e-test-runner
  namespace: argocd-e2e
spec:
  serviceAccountName: default
  containers:
  - name: runner
    image: registry.access.redhat.com/ubi9/ubi:latest
    command: ["sleep", "infinity"]
    volumeMounts:
    - name: workspace
      mountPath: /tmp/argo-e2e
    workingDir: /tmp/argo-e2e
  volumes:
  - name: workspace
    emptyDir: {}
EOF

# Wait for pod ready
kubectl wait --for=condition=Ready pod/e2e-test-runner -n argocd-e2e --timeout=120s

# Install git in the pod
kubectl exec -n argocd-e2e e2e-test-runner -- dnf install -y git
```

### 2. Copy Test Assets to Pod

**Modified:** `run-argocd-e2e-tests.sh`

```bash
# After compiling or finding pre-built tests

echo "Copying test assets to e2e-test-runner pod..."

# Copy test binary
oc cp "${ARGO_CD_DIR}/e2e.test" \
  argocd-e2e/e2e-test-runner:/tmp/argo-e2e/e2e.test

# Copy ArgoCD CLI
oc cp "${ARGO_CD_DIR}/dist/argocd" \
  argocd-e2e/e2e-test-runner:/tmp/argo-e2e/dist/argocd

# Copy entire testdata directory (79 subdirectories with fixtures)
tar -czf /tmp/testdata.tar.gz -C "${ARGO_CD_DIR}/test/e2e" testdata
oc cp /tmp/testdata.tar.gz \
  argocd-e2e/e2e-test-runner:/tmp/argo-e2e/testdata.tar.gz

# Extract in pod
oc exec -n argocd-e2e e2e-test-runner -- \
  tar -xzf /tmp/argo-e2e/testdata.tar.gz -C /tmp/argo-e2e/

# Copy kubectl (tests use it to check resources)
oc cp $(which oc) argocd-e2e/e2e-test-runner:/tmp/bin/kubectl
```

### 3. Run Tests Inside Pod

**Modified:** `run-argocd-e2e-tests.sh`

```bash
# Generate test execution script
cat > /tmp/run_test_remote.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail

export ARGOCD_E2E_REMOTE=true
export ARGOCD_SERVER="${ARGOCD_SERVER}"
export ARGOCD_SERVER_INSECURE=true
export ARGOCD_E2E_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD}"
export ARGOCD_E2E_NAMESPACE=argocd-e2e
export ARGOCD_E2E_GIT_SERVICE="git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git"
export DIST_DIR=/tmp/argo-e2e/dist
export PATH=/tmp/bin:$PATH

cd /tmp/argo-e2e
./e2e.test -test.v
SCRIPT

# Copy script to pod
oc cp /tmp/run_test_remote.sh argocd-e2e/e2e-test-runner:/tmp/run_test_remote.sh

# Execute tests inside pod
oc exec -n argocd-e2e e2e-test-runner -- bash /tmp/run_test_remote.sh
```

### 4. Background Namespace Watcher (Optional but Recommended)

Some tests dynamically create namespaces and expect ArgoCD to manage them.

**New script:** `background-namespace-watcher.sh`

```bash
#!/bin/bash
# Run in background during test execution
# Watches for test-created namespaces and configures ArgoCD to manage them

while true; do
  for ns in $(oc get ns -l e2e.argoproj.io=true -o jsonpath='{.items[*].metadata.name}'); do
    # Label namespace for ArgoCD management
    oc label ns "$ns" argocd.argoproj.io/managed-by=argocd-e2e --overwrite 2>/dev/null || true
    
    # Grant necessary permissions
    oc adm policy add-scc-to-user privileged -z default -n "$ns" 2>/dev/null || true
  done
  sleep 2
done
```

**Run in background:**
```bash
# Start watcher in background
./background-namespace-watcher.sh &
WATCHER_PID=$!

# Run tests
oc exec -n argocd-e2e e2e-test-runner -- bash /tmp/run_test_remote.sh

# Stop watcher
kill $WATCHER_PID
```

### 5. Update Test Task Definition

**Modified:** `.tekton/integration-tests/pipelines/catalog-argocd-e2e.yaml`

```yaml
- name: test-argocd
  runAfter:
    - deploy-argocd
  params:
    - name: ARGOCD_NAMESPACE
      value: $(tasks.deploy-argocd.results.namespace)
    - name: ARGOCD_SERVER
      value: $(tasks.deploy-argocd.results.server)
    - name: ARGOCD_ADMIN_PASSWORD
      value: $(tasks.deploy-argocd.results.adminPassword)
  taskSpec:
    params:
      - name: ARGOCD_NAMESPACE
      - name: ARGOCD_SERVER
      - name: ARGOCD_ADMIN_PASSWORD
    steps:
      - name: deploy-test-runner-pod
        image: $(tasks.build-ginkgo-test-image.results.IMAGE_URL)
        script: |
          #!/bin/bash
          /usr/local/bin/deploy-test-runner-pod.sh
      
      - name: copy-test-assets
        image: $(tasks.build-ginkgo-test-image.results.IMAGE_URL)
        script: |
          #!/bin/bash
          # Test runner pod has pre-compiled tests
          # Just copy them to the runner pod
          /usr/local/bin/copy-test-assets-to-pod.sh
      
      - name: run-tests-in-pod
        image: $(tasks.build-ginkgo-test-image.results.IMAGE_URL)
        env:
          - name: ARGOCD_SERVER
            value: $(params.ARGOCD_SERVER)
          - name: ARGOCD_ADMIN_PASSWORD
            value: $(params.ARGOCD_ADMIN_PASSWORD)
        script: |
          #!/bin/bash
          /usr/local/bin/run-tests-in-pod.sh
```

## Alternative: Use HTTPS Git Server

**If you want to keep tests in Konflux cluster**, you'd need to:

1. Replace git daemon with HTTP-based git server (e.g., gitea, cgit)
2. Expose via Route
3. Configure tests to use HTTPS git URLs
4. Modify test fixtures to support HTTPS auth
5. Handle git credentials in tests

**Complexity:** Very high - would require patching upstream test code and maintaining fork.

**Recommendation:** Don't do this. Use the proven downstream-CI pattern (run tests in pod).

## Summary

**Current approach (run tests from Konflux):** ❌ Cannot work
- Cross-cluster DNS fails
- Git protocol not routable
- No local filesystem access for git operations

**Downstream-CI approach (run tests in test cluster pod):** ✅ Works
- Tests and git-server in same cluster
- Service DNS works
- Git push works
- Local filesystem operations work
- Proven in production

**Required effort:**
- Create `deploy-test-runner-pod.sh` script
- Create `copy-test-assets-to-pod.sh` script  
- Create `run-tests-in-pod.sh` script
- Update test task to use pod-based execution
- Optional: Add background namespace watcher

**Timeline:** ~4-6 hours of implementation + testing
