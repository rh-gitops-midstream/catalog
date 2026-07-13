# GitOps Test Image

This directory contains the test image used for running integration tests in Konflux pipelines.

## Structure

```
.tekton/test-image/
├── Dockerfile              # Final layer: copies scripts + ArgoCD manifests
├── Dockerfile.base         # Layer 1: CLI tools + Go toolchain
├── Dockerfile.testsuites   # Layer 2: Pre-compiled Ginkgo + ArgoCD E2E tests
├── argocd-v2.14.1-install.yaml  # Bundled ArgoCD install manifest (templated)
├── scripts/                # Test helper scripts
│   ├── deploy-argocd-standalone.sh
│   ├── run-argocd-e2e-tests.sh
│   ├── run-parallel-tests.sh
│   └── ...
└── config/                 # Test skip lists
    ├── skip-parallel.txt
    ├── skip-argocd.txt
    └── ...
```

## ArgoCD Install Manifest

### Current Version

- **File:** `argocd-v2.14.1-install.yaml`
- **Source:** https://raw.githubusercontent.com/argoproj/argo-cd/v2.14.1/manifests/install.yaml
- **Modifications:** Namespace references replaced with `ARGOCD_NAMESPACE_PLACEHOLDER`

### Updating ArgoCD Version

To update to a new ArgoCD version (e.g., v2.15.0):

1. **Download upstream install.yaml:**
   ```bash
   VERSION=v2.15.0
   curl -sSL https://raw.githubusercontent.com/argoproj/argo-cd/${VERSION}/manifests/install.yaml \
     > /tmp/argocd-install.yaml
   ```

2. **Replace namespace references:**
   ```bash
   sed 's/namespace: argocd$/namespace: ARGOCD_NAMESPACE_PLACEHOLDER/g' \
     /tmp/argocd-install.yaml \
     > .tekton/test-image/argocd-${VERSION}-install.yaml
   ```

3. **Verify substitution:**
   ```bash
   grep "ARGOCD_NAMESPACE_PLACEHOLDER" .tekton/test-image/argocd-${VERSION}-install.yaml
   # Should show 3 matches (ClusterRoleBinding subjects)
   ```

4. **Update deploy script:**
   Edit `scripts/deploy-argocd-standalone.sh`:
   ```bash
   INSTALL_TEMPLATE="/usr/local/argocd-install/argocd-v2.15.0-install.yaml"
   ```

5. **Update Dockerfile:**
   Edit `Dockerfile`:
   ```dockerfile
   COPY argocd-v2.15.0-install.yaml /usr/local/argocd-install/argocd-v2.15.0-install.yaml
   ```

6. **Update pipeline default:**
   Edit `.tekton/integration-tests/pipelines/catalog-argocd-e2e.yaml`:
   ```yaml
   - description: ArgoCD version for upstream manifests
     name: ARGOCD_VERSION
     default: "v2.15.0"
   ```

7. **Test locally:**
   ```bash
   podman build -f Dockerfile.base -t test-base .
   podman build -f Dockerfile.testsuites --build-arg BASE_IMAGE=test-base -t test-suites .
   podman build -f Dockerfile --build-arg BASE_IMAGE=test-suites -t test-final .
   
   # Verify file exists in image
   podman run --rm test-final ls -lh /usr/local/argocd-install/
   ```

8. **Clean up old version (optional):**
   ```bash
   git rm .tekton/test-image/argocd-v2.14.1-install.yaml
   ```

### Why Bundled Manifest?

**Benefits:**
- ✅ No runtime network dependency on GitHub
- ✅ Exact ArgoCD version controlled in git
- ✅ Faster deployment (no curl download)
- ✅ Works in air-gapped environments
- ✅ Can test manifest changes locally
- ✅ Clear versioning (filename = ArgoCD version)

**Tradeoffs:**
- Large file in git (~26K lines)
- Manual update process when upgrading ArgoCD

### Namespace Placeholder

The template uses `ARGOCD_NAMESPACE_PLACEHOLDER` which is substituted at deployment time:

```bash
sed "s/ARGOCD_NAMESPACE_PLACEHOLDER/${NAMESPACE}/g" \
  /usr/local/argocd-install/argocd-v2.14.1-install.yaml \
  > /tmp/argocd-install.yaml
```

This allows deploying ArgoCD to any namespace (e.g., `argocd-e2e` for tests, `argocd` for production).

Only 3 occurrences need substitution (ClusterRoleBinding subjects that reference ServiceAccounts).

## Building the Test Image

The image is built in 3 layers for efficient caching:

### Layer 1: Base (tools + Go)
```bash
podman build -f Dockerfile.base -t quay.io/devtools_gitops/test_image:base-amd64-<hash> .
```

**Contains:**
- OpenShift CLI (oc)
- jq, yq, git, skopeo
- Go toolchain
- ORAS (for artifact upload)

**Rebuilt when:** Dockerfile.base changes

### Layer 2: Testsuites (pre-compiled tests)
```bash
podman build -f Dockerfile.testsuites \
  --build-arg BASE_IMAGE=quay.io/devtools_gitops/test_image:base-amd64-<hash> \
  -t quay.io/devtools_gitops/test_image:testsuites-amd64-<hash> .
```

**Contains:**
- Pre-compiled GitOps operator Ginkgo tests
- Pre-compiled ArgoCD v2.14.1 E2E tests
- Go module cache

**Rebuilt when:** Dockerfile.base OR Dockerfile.testsuites changes

### Layer 3: Final (scripts)
```bash
podman build -f Dockerfile \
  --build-arg BASE_IMAGE=quay.io/devtools_gitops/test_image:testsuites-amd64-<hash> \
  -t quay.io/devtools_gitops/test_image:final-amd64-<hash> .
```

**Contains:**
- All test scripts
- ArgoCD install manifests
- Test skip lists

**Rebuilt when:** Any Dockerfile, script, or config changes

## Test Scripts

### deploy-argocd-standalone.sh

Deploys ArgoCD in standalone mode (no GitOps operator):

**Inputs (env vars):**
- `ARGOCD_SERVER_IMAGE` - ArgoCD server image to deploy
- `ARGOCD_VERSION` - ArgoCD version (for manifest selection)
- `NAMESPACE` - Target namespace (default: `argocd-e2e`)
- `KUBECONFIG` - Path to kubeconfig

**Outputs (task results):**
- `namespace` - Namespace where ArgoCD is deployed
- `server` - ArgoCD server service DNS name
- `adminPassword` - Admin password from secret
- `serverName` - Server deployment name
- `repoServerName` - Repo-server deployment name
- `applicationControllerName` - App controller deployment name
- `redisName` - Redis deployment name

**What it does:**
1. Create namespace
2. Apply ArgoCD manifests (with namespace substitution)
3. Apply OpenShift patches (SCC, redis secret)
4. Patch server deployment image
5. Wait for deployments to be ready
6. Extract admin password
7. Write task results

### run-argocd-e2e-tests.sh

Runs upstream ArgoCD E2E tests against deployed ArgoCD:

**Inputs (env vars):**
- `ARGOCD_NAMESPACE` - Where ArgoCD is deployed
- `ARGOCD_SERVER` - ArgoCD server service DNS
- `ARGOCD_ADMIN_PASSWORD` - Admin password
- `ARGOCD_SERVER_NAME` - Server deployment name (for finding pods)
- `TEST_REPO_URL` - ArgoCD git repo URL
- `BRANCH` - ArgoCD version/branch to test
- `KUBECONFIG` - Path to kubeconfig

**What it does:**
1. Check for pre-compiled tests (in `/testsuites/argocd/`)
2. Clone and compile if needed
3. Create test namespaces (`argocd-e2e-external`)
4. Deploy git-server pod (for test repos)
5. Set E2E environment variables
6. Run `./e2e.test -test.v`

**Key environment variables set:**
- `ARGOCD_E2E_REMOTE=true` - Run tests remotely
- `ARGOCD_SERVER=<service-dns>:80` - ArgoCD server address
- `ARGOCD_E2E_GIT_SERVICE=git://git-server...` - Git daemon for tests
- `ARGOCD_E2E_NAMESPACE=argocd-e2e` - Test namespace
- `DIST_DIR=/tmp/.../dist` - ArgoCD CLI location

**Does NOT:**
- Deploy ArgoCD (expects it already running)
- Install CRDs (expects them installed)
- Configure operator (standalone mode)

## Pre-compiled Tests

To save ~7 minutes per test run, we pre-compile test binaries in the testsuites layer.

### GitOps Operator Tests
- Location: `/testsuites/gitops-operator/`
- Built from: https://github.com/rh-gitops-release-qa/gitops-operator.git
- Binaries: `parallel.test`, `sequential.test`

### ArgoCD E2E Tests
- Location: `/testsuites/argocd/v2.14/`
- Built from: https://github.com/argoproj/argo-cd.git @ v2.14.1
- Binary: `e2e.test`
- CLI: `dist/argocd`

**Architecture detection:** Tests are compiled for the build platform (amd64 or arm64). The test script checks binary architecture and recompiles if there's a mismatch.

## Skip Lists

Test skip lists in `config/`:

- `skip-parallel.txt` - GitOps operator parallel tests to skip
- `skip-sequential.txt` - GitOps operator sequential tests to skip
- `skip-argocd.txt` - ArgoCD E2E tests to skip
- `skip-ui-e2e.txt` - UI E2E tests to skip

Format: One test name per line, regex supported, `#` for comments.
