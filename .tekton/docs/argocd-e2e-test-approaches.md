# ArgoCD E2E Test Execution Approaches

**Author:** Claude  
**Date:** 2026-05-17  
**Status:** Design Documentation  

## Overview

This document captures the research and analysis of different approaches to running upstream ArgoCD E2E tests in Konflux integration pipelines. It serves as a reference for future implementation work and approach switching.

The core challenge: How to run ArgoCD's upstream E2E test suite (`test/e2e/`) against an ArgoCD deployment in a way that tests catalog/operator builds.

---

## Approach 1: Upstream ArgoCD CI (Local Process Mode)

**Source:** `argoproj/argo-cd/.github/workflows/ci-build.yaml` (test-e2e job)

### Architecture

- **Kubernetes:** K3S installed on GitHub Actions runner (Ubuntu)
- **ArgoCD Deployment:** Components run as **local processes** (not pods), managed by `goreman` (process manager)
- **Test Execution:** E2E test binary runs locally on the runner, communicates with local ArgoCD processes
- **Server Start:** `make start-e2e-local` starts components via Procfile

### Environment Variables

```bash
ARGOCD_FAKE_IN_CLUSTER=true           # Tell ArgoCD it's "in cluster" even though it's not
ARGOCD_E2E_K3S=true                   # Running against K3S
ARGOCD_IN_CI=true                     # CI mode
ARGOCD_E2E_APISERVER_PORT=8088        # API server port (not 8080 due to GH runner conflict)
ARGOCD_APPLICATION_NAMESPACES=argocd-e2e-external,argocd-e2e-external-2
ARGOCD_SERVER=127.0.0.1:8088
```

### Setup Steps (from Makefile)

1. Create namespaces: `argocd-e2e`, `argocd-e2e-external`, `argocd-e2e-external-2`
2. Apply manifests: `kustomize build test/manifests/base | kubectl apply -f -`
   - Includes: CRDs, config, cluster RBAC, notification resources
   - Does NOT include ArgoCD deployments (those run locally)
3. Apply Open Cluster Management CRD for placement decisions
4. Create GPG, SSH, TLS, plugin config directories
5. Start ArgoCD components via goreman:
   ```bash
   ARGOCD_E2E_DIR=$(ARGOCD_E2E_DIR) \
   ARGOCD_SSH_DATA_PATH=$(ARGOCD_E2E_DIR)/app/config/ssh \
   ARGOCD_TLS_DATA_PATH=$(ARGOCD_E2E_DIR)/app/config/tls \
   ARGOCD_GPG_DATA_PATH=$(ARGOCD_E2E_DIR)/app/config/gpg/source \
   ARGOCD_GNUPGHOME=$(ARGOCD_E2E_DIR)/app/config/gpg/keys \
   ARGOCD_GPG_ENABLED=$(ARGOCD_GPG_ENABLED) \
   goreman -f test/container/Procfile start
   ```
6. Wait for http://127.0.0.1:8088/healthz to respond
7. Run: `make test-e2e-local` → `./hack/test.sh` → runs `./e2e.test`

### Test Execution

```bash
# From test-e2e-local target
DIST_DIR=${DIST_DIR} \
RERUN_FAILS=$(ARGOCD_E2E_RERUN_FAILS) \
PACKAGES="./test/e2e" \
ARGOCD_E2E_RECORD=${ARGOCD_E2E_RECORD} \
ARGOCD_CONFIG_DIR=$(HOME)/.config/argocd-e2e \
ARGOCD_GPG_ENABLED=true \
NO_PROXY=* \
./hack/test.sh -timeout $(ARGOCD_E2E_TEST_TIMEOUT) -v -args -test.gocoverdir="$(PWD)/test-results"
```

### Pros

- **Most authentic upstream experience** - exact same setup as ArgoCD project CI
- **Fast** - no container overhead, direct process communication
- **Coverage support** - built-in support for Go coverage collection
- **Well-tested** - used daily by ArgoCD maintainers

### Cons

- **Complex setup** - requires goreman, local process management, many environment paths
- **Not containerized** - hard to integrate with Konflux Tekton pipelines
- **Image testing challenge** - how to inject catalog-extracted ArgoCD image into local processes?
- **Platform-specific** - assumes Linux runner with specific tooling

### Integration with Katalog Testing

**Challenge:** How to test the ArgoCD image extracted from the catalog?

**Possible solution:**
1. Build ArgoCD server/controller/repo-server binaries from extracted image
2. Extract binaries from image: `oc image extract $ARGOCD_IMAGE --path /usr/local/bin/argocd-server:/tmp/bins`
3. Override Procfile paths to use extracted binaries
4. Still requires matching Go environment, dependencies

**Complexity:** High - would need to adapt Procfile, environment setup, binary paths

---

## Approach 2: Downstream-CI (Operator + Remote Execution)

**Source:** `downstream-CI/scripts/tasks/single-argocd-e2e-test.sh`

### Architecture

- **Kubernetes:** Existing OpenShift cluster with GitOps operator pre-installed
- **ArgoCD Deployment:** Deployed via **ArgoCD CR** (operator-managed)
- **Test Execution:** E2E test binary runs **inside a pod** in the cluster
- **Test Mode:** Remote reuse - tests connect to existing ArgoCD, skip setup

### Environment Variables

```bash
# Set inside e2e-test-runner pod
ARGOCD_E2E_SKIP_SETUP=true              # Don't deploy ArgoCD (already exists)
ARGOCD_E2E_REUSE_SERVER=true            # Reuse existing ArgoCD server
ARGOCD_E2E_REMOTE=true                  # Running remotely in cluster
ARGOCD_E2E_NAMESPACE=argocd-e2e         # Test namespace
ARGOCD_E2E_NAME_PREFIX=argocd-test      # ArgoCD instance name prefix
ARGOCD_E2E_WAIT_TIMEOUT=120             # Timeout for operations
ARGOCD_E2E_APISERVER_URL=https://argocd-test-server
ARGOCD_SERVER=argocd-test-server.argocd-e2e.svc.cluster.local:80
ARGOCD_SERVER_INSECURE=true
ARGOCD_E2E_INSECURE=true
ARGOCD_AUTH_TOKEN=$ARGOCD_AUTH_TOKEN    # Generated from admin password
ARGOCD_E2E_ADMIN_PASSWORD=$ADMIN_PASS
DIST_DIR=/tmp/argo-cd/dist
ARGOCD_E2E_GIT_SERVICE=git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git
ARGOCD_E2E_REPO_DEFAULT=git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git
ARGOCD_E2E_DIR=/tmp/argo-e2e
```

### Setup Steps

1. **Configure operator for test namespace:**
   ```bash
   oc set env deployment/$OP_DEPLOY -n $OP_NS \
     DISABLE_DEFAULT_ARGOCD_INSTANCE=true \
     ARGOCD_CLUSTER_CONFIG_NAMESPACES=openshift-gitops,argocd-e2e -c manager
   ```

2. **Create test namespace and RBAC:**
   ```bash
   oc new-project argocd-e2e
   oc -n argocd-e2e adm policy add-scc-to-user privileged -z default
   oc adm policy add-cluster-role-to-user cluster-admin -z default -n argocd-e2e
   ```

3. **Deploy ArgoCD via CR:**
   ```yaml
   apiVersion: argoproj.io/v1beta1
   kind: ArgoCD
   metadata:
     name: argocd-test
     namespace: argocd-e2e
   spec:
     server:
       insecure: true
       route: { enabled: false }
     repo:
       image: quay.io/argoproj/argocd
       version: "${TAG}"
     redis: { image: redis, version: "7" }
     rbac:
       defaultPolicy: 'role:admin'
     applicationSet: {}
     controller:
       env:
         - name: ARGOCD_K8S_CLIENT_QPS
           value: "300"
         - name: ARGOCD_K8S_CLIENT_BURST
           value: "600"
   ```

4. **Lock operator configuration (prevent reconciliation):**
   ```bash
   # Pause reconciliation
   oc annotate argocd argocd-test -n argocd-e2e \
     argocd.argoproj.io/operator-pause-reconciliation="true" --overwrite
   
   # Scale down operators
   oc scale deploy -l app.kubernetes.io/name=openshift-gitops-operator -A --replicas=0
   oc scale deploy -l app.kubernetes.io/part-of=argocd-operator -A --replicas=0
   ```

5. **Configure cluster secret:**
   ```bash
   # Remove restrictive defaults
   oc delete secret -n argocd-e2e -l argocd.argoproj.io/secret-type=cluster --ignore-not-found
   
   # Create permissive cluster config
   cat <<EOF | oc apply -n argocd-e2e -f -
   apiVersion: v1
   kind: Secret
   metadata:
     labels:
       argocd.argoproj.io/secret-type: cluster
     name: argocd-test-default-cluster-config
   stringData:
     config: '{"tlsClientConfig":{"insecure":false}}'
     name: in-cluster
     server: https://kubernetes.default.svc
     namespaces: "argocd-e2e"
   EOF
   ```

6. **Create test infrastructure pods:**
   ```yaml
   # Git server for test repos
   apiVersion: v1
   kind: Pod
   metadata: { name: git-server, labels: { app: git-server } }
   spec:
     containers:
     - name: git-server
       image: bitnami/git:latest
       command: ["/bin/sh", "-c"]
       args:
         - |
           mkdir -p /git/testdata.git && cd /git/testdata.git && \
           git init --bare && touch git-daemon-export-ok && \
           git daemon --base-path=/git --export-all --enable=receive-pack \
             --port=9418 --verbose
   ---
   # Test runner pod (uses ArgoCD image)
   apiVersion: v1
   kind: Pod
   metadata:
     name: e2e-test-runner
     namespace: argocd-e2e
   spec:
     serviceAccountName: default
     containers:
     - name: runner
       image: quay.io/argoproj/argocd:${TAG}
       command: ["/bin/sh", "-c", "tail -f /dev/null"]
   ```

7. **Copy test artifacts into pod:**
   ```bash
   oc cp "${ARGO_CD_DIR}/e2e.test" "argocd-e2e/e2e-test-runner:/tmp/argo-cd/"
   oc cp "${ARGO_CD_DIR}/dist/argocd" "argocd-e2e/e2e-test-runner:/tmp/argo-cd/dist/"
   oc cp "${ARGO_CD_DIR}/test-fixtures.tar.gz" "argocd-e2e/e2e-test-runner:/tmp/argo-cd/"
   oc cp "$(which oc)" "argocd-e2e/e2e-test-runner:/tmp/bin/kubectl"
   ```

8. **Run tests inside pod:**
   ```bash
   oc exec -n argocd-e2e e2e-test-runner -- sh /tmp/run_test_remote.sh
   ```

### Background Watcher Pattern

Downstream-CI runs a **background watcher** to handle dynamic namespace creation by tests:

```bash
(
  while true; do
    # Find namespaces labeled by tests
    for ns in $(oc get ns -l e2e.argoproj.io=true -o jsonpath='{.items[*].metadata.name}'); do
      # Label for operator management
      oc label ns "$ns" argocd.argoproj.io/managed-by=argocd-e2e --overwrite
      
      # Add to cluster secret allow-list
      oc patch secret argocd-test-default-cluster-config -n argocd-e2e \
        --type='merge' -p="{\"stringData\":{\"namespaces\":\"$NEW_NS\"}}"
      
      # Force refresh to bypass backoff
      for app in $(oc get application -n argocd-e2e -o jsonpath='{.items[*].metadata.name}'); do
        oc annotate application "$app" -n argocd-e2e \
          argocd.argoproj.io/refresh="hard" --overwrite
      done
    done
    sleep 1
  done
) &
```

### Pros

- **Works with operator-managed ArgoCD** - tests what we ship
- **Proven in downstream** - battle-tested in Red Hat CI
- **Realistic environment** - tests run in cluster, same as production
- **Easy image substitution** - ArgoCD CR spec controls image
- **Handles OpenShift quirks** - SCC, RBAC, namespaces

### Cons

- **Requires operator** - must install GitOps operator first
- **Complex setup** - many moving parts (operator config, pausing, scaling, secrets)
- **Slower** - pod startup, container overhead, oc cp transfers
- **Operator dependency** - operator bugs affect ArgoCD E2E tests

### Integration with Catalog Testing

**How to test catalog-extracted ArgoCD image:**

1. Install GitOps operator (already done in catalog-gitops-operator-e2e)
2. Extract ArgoCD image from catalog (already implemented)
3. Deploy ArgoCD CR with catalog image:
   ```yaml
   spec:
     repo:
       image: quay.io/redhat-user-workloads/.../argocd-rhel9
       version: sha256:abc123...
     server:
       image: quay.io/redhat-user-workloads/.../argocd-rhel9
       version: sha256:abc123...
   ```
4. Run E2E tests against operator-deployed ArgoCD

**Complexity:** Medium - reuses existing operator installation, straightforward image substitution

---

## Approach 3: Current Implementation (Dual Mode - Standalone/Operator)

**Source:** `catalog/.tekton/test-image/scripts/run-argocd-e2e-tests.sh`

### Architecture

- **Kubernetes:** OpenShift cluster (ephemeral or existing)
- **ArgoCD Deployment:** Supports two modes via `DEPLOY_MODE` env var:
  - `standalone`: Deploy ArgoCD from upstream manifests (no operator)
  - `operator`: Deploy via ArgoCD CR (like downstream-CI)
- **Test Execution:** E2E test binary runs **locally** (not in pod)

### Standalone Mode Logic

```bash
if [[ "${DEPLOY_MODE}" == "standalone" ]]; then
  # Apply CRDs
  oc apply -f "${ARGO_CD_DIR}/manifests/crds/" -n argocd-e2e
  
  # Prepare install.yaml with custom image
  cp "${ARGO_CD_DIR}/manifests/install.yaml" "${ROOT_DIR}/install-patched.yaml"
  sed -i "s|quay.io/argoproj/argocd:.*|${ARGOCD_IMAGE}|g" "${ROOT_DIR}/install-patched.yaml"
  sed -i '/^  namespace: argocd$/s/argocd/argocd-e2e/' "${ROOT_DIR}/install-patched.yaml"
  
  # Apply manifests
  oc apply -f "${ROOT_DIR}/install-patched.yaml" -n argocd-e2e
  
  # Wait for deployments
  oc wait --for=condition=Available deployment/argocd-server -n argocd-e2e --timeout=300s
  oc wait --for=condition=Available deployment/argocd-repo-server -n argocd-e2e --timeout=300s
  oc rollout status deployment/argocd-application-controller -n argocd-e2e --timeout=300s || \
    oc rollout status statefulset/argocd-application-controller -n argocd-e2e --timeout=300s
fi
```

### Operator Mode Logic

```bash
else
  # Configure operator
  oc set env "deployment/$OP_DEPLOY" -n "$OP_NS" \
    DISABLE_DEFAULT_ARGOCD_INSTANCE=true \
    ARGOCD_CLUSTER_CONFIG_NAMESPACES=openshift-gitops,argocd-e2e -c manager
  
  # Deploy ArgoCD CR
  cat <<EOF | oc apply -f -
  apiVersion: argoproj.io/v1beta1
  kind: ArgoCD
  metadata:
    name: argocd-test
    namespace: argocd-e2e
  spec:
    sourceNamespaces:
      - "argocd-e2e-external"
      - "argocd-e2e-external-2"
    server:
      insecure: true
      route: { enabled: false }
    rbac:
      defaultPolicy: 'role:admin'
    applicationSet: {}
    controller:
      env:
        - name: ARGOCD_K8S_CLIENT_QPS
          value: "300"
        - name: ARGOCD_K8S_CLIENT_BURST
          value: "600"
  EOF
  
  # Pause reconciliation and scale down
  oc annotate argocd argocd-test -n argocd-e2e \
    argocd.argoproj.io/operator-pause-reconciliation="true" --overwrite
  oc scale deploy -l app.kubernetes.io/name=openshift-gitops-operator -A --replicas=0
fi
```

### Test Execution (Local Mode)

Tests run locally, NOT in a pod:

```bash
cd "${ARGO_CD_DIR}/test/e2e"
./../../e2e.test -test.v -test.timeout 60m \
  ${ARGOCD_E2E_SKIP:+-test.skip "$ARGOCD_E2E_SKIP"} 2>&1 | tee "${RESULTS_DIR}/test.log"
```

### Why It's Failing

**Error:** `no matches for kind "ArgoCD" in version "argoproj.io/v1beta1"`

**Root cause:** Some test fixtures (`test/e2e/fixture/app`) try to deploy ArgoCD via CR. In standalone mode:
- ArgoCD CRD is not installed (no operator)
- Tests fail when trying to `oc apply -f` a manifest with `kind: ArgoCD`

**Example failing test:** Tests that need to deploy their own ArgoCD instance as part of setup.

### Pros

- **Flexible** - supports both standalone and operator modes
- **Pre-compiled tests** - fast test binary reuse (no 7-minute compilation)
- **Architecture detection** - handles amd64/arm64 correctly
- **Good logging** - task logs uploaded to Quay

### Cons

- **Incomplete standalone support** - tests expect operator/CRD
- **Missing remote mode** - tests run locally, not in cluster
- **No background watcher** - dynamic namespace handling missing
- **Partial implementation** - combines upstream + downstream patterns incompletely

### Integration with Catalog Testing

**Current flow:**
1. Extract ArgoCD image from catalog (working)
2. Deploy ArgoCD standalone with extracted image (working)
3. Run tests locally (failing - CRD not found)

**Fix options:**
- **Option A:** Switch to operator mode, patch CR with catalog image
- **Option B:** Set `ARGOCD_E2E_SKIP` to exclude tests requiring ArgoCD CR
- **Option C:** Run tests in remote mode inside pod (like downstream-CI)

---

## Approach 4: Hybrid (Operator + Catalog Image + E2E Tests)

**Proposed combination of existing approaches**

### Architecture

- Use **catalog-gitops-operator-e2e pipeline** infrastructure (operator installation, cluster provisioning)
- Add **ArgoCD E2E test stage** after operator E2E tests
- Extract ArgoCD image from catalog (parallel with provisioning)
- Patch operator-deployed ArgoCD with catalog image
- Run ArgoCD E2E tests in remote mode (like downstream-CI)

### Pipeline Flow

```yaml
tasks:
  - name: parse-metadata
  - name: build-test-image (parallel)
  - name: provision-eaas-space (parallel)
  - name: extract-argocd-image (parallel, after build-test-image)
  - name: provision-cluster (after provision-eaas-space)
  - name: install-operator (after provision-cluster + build-test-image)
  - name: test-operator (after install-operator)  # Existing operator E2E tests
  - name: test-argocd-e2e (after test-operator)    # NEW: ArgoCD E2E tests
    steps:
      - configure-argocd-for-e2e
      - deploy-test-infrastructure  # git-server, e2e-runner pod
      - patch-argocd-image          # Use catalog-extracted image
      - run-argocd-e2e-tests        # Remote execution
```

### ArgoCD E2E Test Task

```yaml
- name: test-argocd-e2e
  runAfter:
    - test-operator
  params:
    - name: argoCDImage
      value: $(tasks.extract-argocd-image.results.argoCDImage)
    - name: testImageUrl
      value: $(tasks.build-test-image.results.IMAGE_URL)
  taskSpec:
    steps:
      - name: patch-argocd-image
        script: |
          # Patch the existing openshift-gitops ArgoCD instance
          oc patch argocd openshift-gitops -n openshift-gitops \
            --type merge -p "{\"spec\":{\"repo\":{\"image\":\"${ARGOCD_IMAGE%:*}\",\"version\":\"${ARGOCD_IMAGE#*:}\"}}}"
          
          # Wait for rollout
          oc rollout status deployment/openshift-gitops-repo-server -n openshift-gitops
      
      - name: create-test-namespace
        script: |
          oc new-project argocd-e2e
          oc -n argocd-e2e adm policy add-scc-to-user privileged -z default
      
      - name: deploy-argocd-test-instance
        script: |
          # Create ArgoCD CR for E2E tests (using catalog image)
          cat <<EOF | oc apply -f -
          apiVersion: argoproj.io/v1beta1
          kind: ArgoCD
          metadata:
            name: argocd-test
            namespace: argocd-e2e
          spec:
            sourceNamespaces: ["argocd-e2e-external", "argocd-e2e-external-2"]
            server: { insecure: true, route: { enabled: false } }
            repo: { image: "${ARGOCD_IMAGE%:*}", version: "${ARGOCD_IMAGE#*:}" }
            controller:
              env:
                - { name: ARGOCD_K8S_CLIENT_QPS, value: "300" }
                - { name: ARGOCD_K8S_CLIENT_BURST, value: "600" }
          EOF
      
      - name: deploy-test-infrastructure
        # Deploy git-server, e2e-runner pod (like downstream-CI)
      
      - name: run-e2e-tests
        # Copy test binary into pod, execute remotely
```

### Pros

- **Comprehensive testing** - tests both operator AND ArgoCD E2E in one run
- **Reuses infrastructure** - builds on existing catalog pipeline
- **Tests catalog image** - validates extracted ArgoCD image
- **Proven patterns** - combines working pieces from upstream + downstream

### Cons

- **Long runtime** - operator E2E + ArgoCD E2E = 60+ minutes
- **Complex pipeline** - many tasks, dependencies
- **Resource intensive** - multiple ArgoCD instances in one cluster
- **Harder to debug** - failures could be operator or ArgoCD issues

---

## Key Test Environment Variables Reference

### Setup Control

| Variable | Values | Purpose |
|----------|--------|---------|
| `ARGOCD_E2E_SKIP_SETUP` | true/false | Skip ArgoCD deployment (use existing) |
| `ARGOCD_E2E_REUSE_SERVER` | true/false | Reuse existing ArgoCD server |
| `ARGOCD_E2E_REMOTE` | true/false | Running remotely in cluster vs locally |
| `ARGOCD_FAKE_IN_CLUSTER` | true/false | Fake in-cluster mode for local processes |
| `ARGOCD_E2E_K3S` | true/false | Running against K3S |
| `ARGOCD_IN_CI` | true/false | Running in CI environment |

### Connectivity

| Variable | Example | Purpose |
|----------|---------|---------|
| `ARGOCD_SERVER` | `127.0.0.1:8088` or `argocd-test-server.argocd-e2e.svc:80` | ArgoCD API server address |
| `ARGOCD_E2E_APISERVER_URL` | `https://argocd-test-server` | API server URL |
| `ARGOCD_SERVER_INSECURE` | true | Skip TLS verification |
| `ARGOCD_AUTH_TOKEN` | `eyJhbGc...` | Authentication token |
| `ARGOCD_E2E_ADMIN_PASSWORD` | `password` | Admin password |

### Namespaces

| Variable | Example | Purpose |
|----------|---------|---------|
| `ARGOCD_E2E_NAMESPACE` | `argocd-e2e` | Test namespace |
| `ARGOCD_E2E_NAME_PREFIX` | `argocd-test` | ArgoCD instance name prefix |
| `ARGOCD_APPLICATION_NAMESPACES` | `argocd-e2e-external,argocd-e2e-external-2` | Application namespaces |

### Git Repository

| Variable | Example | Purpose |
|----------|---------|---------|
| `ARGOCD_E2E_GIT_SERVICE` | `git://git-server.argocd-e2e.svc:9418/testdata.git` | Git daemon URL |
| `ARGOCD_E2E_REPO_DEFAULT` | `git://git-server.argocd-e2e.svc:9418/testdata.git` | Default test repo |
| `ARGOCD_E2E_GIT_SERVICE_SUBMODULE` | URL | Git submodule test URL |

### Paths

| Variable | Example | Purpose |
|----------|---------|---------|
| `DIST_DIR` | `/tmp/argo-cd/dist` | ArgoCD CLI binary location |
| `ARGOCD_E2E_DIR` | `/tmp/argo-e2e` | Test working directory |
| `ARGOCD_CONFIG_DIR` | `~/.config/argocd-e2e` | ArgoCD config directory |
| `ARGOCD_SSH_DATA_PATH` | `~/.ssh` | SSH keys path |
| `ARGOCD_TLS_DATA_PATH` | `~/tls` | TLS certs path |
| `ARGOCD_GPG_DATA_PATH` | `~/gpg/source` | GPG keys path |
| `ARGOCD_GNUPGHOME` | `~/gpg/keys` | GPG home directory |

### Test Skipping

| Variable | Format | Purpose |
|----------|--------|---------|
| `ARGOCD_E2E_SKIP` | `TestFoo\|TestBar` | Regex of tests to skip |
| `ARGOCD_E2E_SKIP_<SUFFIX>` | `true/false` | Skip specific test categories |

Tests check: `os.Getenv("ARGOCD_E2E_SKIP_" + suffix)`

### Timeouts

| Variable | Default | Purpose |
|----------|---------|---------|
| `ARGOCD_E2E_WAIT_TIMEOUT` | 120 | Timeout for test operations (seconds) |
| `ARGOCD_E2E_TEST_TIMEOUT` | varies | Overall test timeout |

---

## Comparison Matrix

| Aspect | Upstream CI | Downstream-CI | Current | Hybrid |
|--------|-------------|---------------|---------|--------|
| **ArgoCD Deployment** | Local processes | Operator CR | Standalone or Operator | Operator CR |
| **Test Execution** | Local | Remote (in pod) | Local | Remote (in pod) |
| **Operator Required** | No | Yes | Optional | Yes |
| **Catalog Image Testing** | Hard | Easy | Medium | Easy |
| **Setup Complexity** | High | Medium | Medium | High |
| **Runtime** | Fast (~15 min) | Medium (~30 min) | Medium (~30 min) | Slow (~60 min) |
| **OpenShift Compatibility** | Needs adaptation | Native | Native | Native |
| **Maintenance Burden** | High | Low | Medium | Medium |
| **Coverage** | ArgoCD only | ArgoCD only | ArgoCD only | Operator + ArgoCD |

---

## Recommendations

### For Current Needs (Catalog ArgoCD Testing)

**Use Approach 2 (Downstream-CI pattern):**

1. Install GitOps operator (reuse catalog-gitops-operator-e2e infrastructure)
2. Extract ArgoCD image from catalog (already implemented)
3. Deploy ArgoCD via CR with catalog image
4. Run E2E tests in remote mode (copy test binary into pod)
5. Use background watcher for dynamic namespace handling

**Why:** Proven in production, straightforward image substitution, handles OpenShift correctly.

### For Upstream Parity

**Use Approach 1 (Upstream CI pattern):**

- When contributing tests back to upstream ArgoCD
- When debugging test failures that don't reproduce in operator mode
- For development/debugging of ArgoCD itself

**Note:** Requires significant adaptation for Konflux/OpenShift environment.

### For Comprehensive CI

**Use Approach 4 (Hybrid):**

- When you want both operator validation AND ArgoCD E2E coverage
- For release testing where full coverage is critical
- Accept longer runtime (~60 min) for comprehensive validation

### Migration Path

**Short-term:** Fix current pipeline to use operator mode + remote execution (Approach 2)

**Medium-term:** Consider splitting into two pipelines:
- **catalog-argocd-e2e** - ArgoCD E2E tests only (Approach 2)
- **catalog-operator-e2e** - Operator E2E tests only (existing)

**Long-term:** Evaluate Approach 4 (Hybrid) if comprehensive coverage justifies runtime cost

---

## Implementation Checklist

### For Switching to Approach 2 (Downstream-CI)

- [ ] Remove standalone mode logic from `run-argocd-e2e-tests.sh`
- [ ] Add operator configuration step (DISABLE_DEFAULT_ARGOCD_INSTANCE, ARGOCD_CLUSTER_CONFIG_NAMESPACES)
- [ ] Add operator scaling down logic (prevent reconciliation)
- [ ] Add git-server pod deployment
- [ ] Add e2e-test-runner pod deployment
- [ ] Add test binary/fixtures copy to pod (`oc cp`)
- [ ] Add remote execution script generation
- [ ] Add background namespace watcher
- [ ] Set remote mode environment variables
- [ ] Update test execution to use `oc exec`
- [ ] Add operator restoration in cleanup

### For Switching to Approach 1 (Upstream CI)

- [ ] Install goreman in test image
- [ ] Add Procfile for ArgoCD components
- [ ] Create local directories for GPG, SSH, TLS, plugin configs
- [ ] Apply test manifests via kustomize
- [ ] Start ArgoCD components as local processes
- [ ] Wait for API server health check
- [ ] Run tests locally
- [ ] Extract binaries from catalog image
- [ ] Override Procfile paths to use catalog binaries

### For Switching to Approach 4 (Hybrid)

- [ ] Extend catalog-gitops-operator-e2e pipeline
- [ ] Add argocd-e2e namespace creation
- [ ] Add ArgoCD CR deployment for testing
- [ ] Add image patching step
- [ ] Add test infrastructure deployment (git-server, runner pod)
- [ ] Add remote test execution
- [ ] Ensure operator tests complete first
- [ ] Add combined result reporting

---

## References

- **Upstream ArgoCD CI:** `argoproj/argo-cd/.github/workflows/ci-build.yaml`
- **Upstream Makefile:** `argoproj/argo-cd/Makefile` (targets: `start-e2e-local`, `test-e2e-local`)
- **Upstream Test Manifests:** `argoproj/argo-cd/test/manifests/base/`
- **Downstream-CI Script:** `downstream-CI/scripts/tasks/single-argocd-e2e-test.sh`
- **Current Implementation:** `catalog/.tekton/test-image/scripts/run-argocd-e2e-tests.sh`
- **Test Fixture Code:** `argoproj/argo-cd/test/e2e/fixture/fixture.go`

---

## Open Questions

1. **Test stability:** Which tests from upstream are flaky in OpenShift? Need skip list?
2. **Resource requirements:** What CPU/memory do ArgoCD E2E tests need?
3. **Timeout values:** What's reasonable for OpenShift vs upstream CI?
4. **Coverage goals:** Do we need 100% upstream test coverage, or is subset OK?
5. **Maintenance:** Who updates when upstream changes E2E test setup?

---

## Appendix: Test Fixture Discovery

The ArgoCD E2E test suite expects certain environment variables to detect its execution mode:

**From `test/e2e/fixture/fixture.go`:**

```go
func IsRemote() bool {
    return env.ParseBoolFromEnv("ARGOCD_E2E_REMOTE", false)
}

func SkipTest(t *testing.T, suffix string) {
    e := os.Getenv("ARGOCD_E2E_SKIP_" + suffix)
    if e == "true" || e == "1" {
        t.Skipf("test skipped due to ARGOCD_E2E_SKIP_%s", suffix)
    }
}
```

**Git service configuration:**

```go
if os.Getenv("ARGOCD_E2E_GIT_SERVICE") != "" {
    _, err = Run(repoDirectory(), "git", "remote", "add", "origin", 
                 os.Getenv("ARGOCD_E2E_GIT_SERVICE"))
}
```

This confirms tests can run in **remote mode** when `ARGOCD_E2E_REMOTE=true` is set.
