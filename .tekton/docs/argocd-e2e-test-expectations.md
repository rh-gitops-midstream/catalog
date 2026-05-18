# ArgoCD E2E Test Suite Expectations Analysis

**Date:** 2026-05-17  
**Source:** `argoproj/argo-cd/test/e2e/fixture/fixture.go`  
**Purpose:** Document what the upstream ArgoCD E2E test suite expects from its environment

---

## Executive Summary

The ArgoCD E2E test suite **does NOT deploy ArgoCD itself**. It expects:

1. **ArgoCD is already running** and accessible
2. **Kubernetes cluster is configured** (via KUBECONFIG)
3. **Test namespaces exist** (`argocd-e2e`, `argocd-e2e-external`)
4. **Git service is running** (if ARGOCD_E2E_REMOTE=true)
5. **Admin credentials are available** for logging in

The test suite focuses on **testing ArgoCD behavior**, not deployment.

---

## Execution Modes

### Local Mode (ARGOCD_E2E_REMOTE=false, default)

**Characteristics:**
- Tests run on same machine as ArgoCD
- Git repositories are local file:// URLs
- ArgoCD server expected at localhost:8080
- Tests create local git repos in /tmp/argo-e2e/

**Use case:** Upstream CI (GitHub Actions with goreman)

### Remote Mode (ARGOCD_E2E_REMOTE=true)

**Characteristics:**
- Tests run remotely, connect to ArgoCD over network
- Git repositories pushed to remote git daemon
- ArgoCD server at configurable address
- Tests push to ARGOCD_E2E_GIT_SERVICE

**Use case:** Testing ArgoCD deployed in Kubernetes cluster

---

## Required Environment Variables

### Connection to ArgoCD

| Variable | Default | Description | Example |
|----------|---------|-------------|---------|
| `ARGOCD_SERVER` | `localhost:8080` | ArgoCD API server address | `argocd-test-server.argocd-e2e.svc.cluster.local:80` |
| `ARGOCD_E2E_ADMIN_USERNAME` | `admin` | Admin username | `admin` |
| `ARGOCD_E2E_ADMIN_PASSWORD` | `password` | Admin password | `<from secret>` |
| `ARGOCD_SERVER_INSECURE` | false | Skip TLS verification | `true` |

### Namespaces

| Variable | Default | Description |
|----------|---------|-------------|
| `ARGOCD_E2E_NAMESPACE` | `argocd-e2e` | Namespace where ArgoCD is deployed |
| `ARGOCD_E2E_APP_NAMESPACE` | `argocd-e2e-external` | Namespace for test applications |

### Component Names (Operator Mode)

These are used to find pods for log collection, restarts, etc.

| Variable | Default | Description |
|----------|---------|-------------|
| `ARGOCD_E2E_SERVER_NAME` | `argocd-server` | Server deployment name |
| `ARGOCD_E2E_REDIS_NAME` | `argocd-redis` | Redis deployment name |
| `ARGOCD_E2E_REDIS_HAPROXY_NAME` | `argocd-redis-ha-haproxy` | Redis HA proxy name |
| `ARGOCD_E2E_REPO_SERVER_NAME` | `argocd-repo-server` | Repo server deployment name |
| `ARGOCD_E2E_APPLICATION_CONTROLLER_NAME` | `argocd-application-controller` | App controller name |

**Note:** In operator mode, these are prefixed with the ArgoCD CR name. Example:
- ArgoCD CR name: `argocd-test`
- Server deployment: `argocd-test-server`
- Set `ARGOCD_E2E_SERVER_NAME=argocd-test-server`

### Execution Mode

| Variable | Default | Description |
|----------|---------|-------------|
| `ARGOCD_E2E_REMOTE` | `false` | Running remotely vs locally |
| `ARGOCD_E2E_DIR` | `/tmp/argo-e2e` | Working directory for test data |

### Git Service (Required for Remote Mode)

| Variable | Example | Description |
|----------|---------|-------------|
| `ARGOCD_E2E_GIT_SERVICE` | `git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git` | Git daemon URL |
| `ARGOCD_E2E_GIT_SERVICE_SUBMODULE` | `git://git-server.argocd-e2e.svc.cluster.local:9418/submodule.git` | Submodule git URL |
| `ARGOCD_E2E_GIT_SERVICE_SUBMODULE_PARENT` | `git://git-server.argocd-e2e.svc.cluster.local:9418/submoduleParent.git` | Submodule parent git URL |

### CLI Path

| Variable | Default | Description |
|----------|---------|-------------|
| `DIST_DIR` | N/A | Directory containing `argocd` CLI binary | 

**Note:** Tests run `../../dist/argocd` relative to test/e2e directory

---

## What Tests DO

### Initialization (fixture.go init())

1. **Load kubeconfig** and create Kubernetes clients
2. **Connect to ArgoCD API server** at `ARGOCD_SERVER`
3. **Test TLS** to determine plaintext vs encrypted connection
4. **Login as admin** using `ARGOCD_E2E_ADMIN_USERNAME` / `ARGOCD_E2E_ADMIN_PASSWORD`
5. **Create ArgoCD API client** for test operations

**Does NOT:**
- Deploy ArgoCD
- Create namespaces
- Install CRDs
- Configure RBAC

### Per-Test Setup (EnsureCleanState)

For each test execution:

1. **Clean up resources from previous tests:**
   - Applications in test namespaces
   - AppProjects (except `default`)
   - Repository secrets
   - Cluster secrets
   - Test-labeled ClusterRoles/ClusterRoleBindings
   - Test-labeled namespaces

2. **Create git repository** (local mode) or **push to git service** (remote mode)

3. **Create deployment namespace** for the specific test (labeled with `e2e.argoproj.io=true`)

**Does NOT:**
- Restart ArgoCD components
- Modify ArgoCD configuration
- Create ArgoCD CR

---

## What Tests DO NOT DO

The test suite **does not** handle:

1. **ArgoCD Installation**
   - No kubectl apply of ArgoCD manifests
   - No ArgoCD CR creation
   - No operator installation

2. **Namespace Creation**
   - `argocd-e2e` must exist before tests run
   - `argocd-e2e-external` must exist before tests run

3. **RBAC Setup**
   - Assumes service accounts have correct permissions
   - Assumes ArgoCD has cluster-admin or sufficient RBAC

4. **Git Service Deployment**
   - In remote mode, assumes git daemon is running
   - Tests just push to it

5. **Infrastructure Setup**
   - No cluster provisioning
   - No ingress/route configuration
   - No TLS certificate generation

---

## Deployment Expectations

### What Must Exist Before Tests Run

#### ArgoCD Components

Must be deployed and ready:
- `argocd-server` deployment/pod
- `argocd-repo-server` deployment/pod
- `argocd-application-controller` deployment or statefulset/pod
- `argocd-redis` deployment/pod (or redis-ha)
- `argocd-applicationset-controller` deployment/pod (optional)
- `argocd-notifications-controller` deployment/pod (optional)

#### Namespaces

Must exist:
- `argocd-e2e` - Where ArgoCD is deployed
- `argocd-e2e-external` - For test applications

#### Secrets

Must exist in `argocd-e2e` namespace:
- Admin password secret (can be initial-admin-secret or cluster secret depending on ArgoCD version)

#### CRDs

Must be installed:
- `applications.argoproj.io`
- `appprojects.argoproj.io`
- `applicationsets.argoproj.io` (if testing ApplicationSets)

#### RBAC

Service account in `argocd-e2e` namespace needs:
- Read/write access to Applications, AppProjects
- Ability to create test namespaces
- Ability to create ClusterRoles/ClusterRoleBindings for tests

ArgoCD itself needs:
- Sufficient permissions to manage applications (typically cluster-admin in test scenarios)

#### Git Service (Remote Mode Only)

Must be deployed and accessible:
- Git daemon listening on port 9418
- Accepts pushes (receive-pack enabled)
- Accessible at ARGOCD_E2E_GIT_SERVICE URL

---

## Test Flow Example

### Local Mode (Upstream CI)

```bash
# 1. EXTERNAL: Start ArgoCD as local processes via goreman
make start-e2e-local

# 2. EXTERNAL: Wait for API server to be ready
curl http://localhost:8080/healthz

# 3. RUN TESTS: Tests connect to localhost:8080
export ARGOCD_SERVER=localhost:8080
export ARGOCD_E2E_ADMIN_PASSWORD=password
./e2e.test -test.v

# Test suite:
# - Connects to ArgoCD at localhost:8080
# - Creates local git repos in /tmp/argo-e2e/
# - Deploys test applications
# - Verifies ArgoCD behavior
# - Cleans up test resources
```

### Remote Mode (Downstream CI, Our Use Case)

```bash
# 1. EXTERNAL: Deploy ArgoCD via operator or standalone
oc apply -f argocd-cr.yaml  # OR oc apply -f manifests/install.yaml

# 2. EXTERNAL: Deploy git daemon
oc apply -f git-server.yaml

# 3. EXTERNAL: Get admin password
ADMIN_PASS=$(oc get secret argocd-cluster -n argocd-e2e -o jsonpath='{.data.admin\.password}' | base64 -d)

# 4. RUN TESTS: Configure and run
export ARGOCD_E2E_REMOTE=true
export ARGOCD_SERVER=argocd-test-server.argocd-e2e.svc.cluster.local:80
export ARGOCD_SERVER_INSECURE=true
export ARGOCD_E2E_ADMIN_PASSWORD=$ADMIN_PASS
export ARGOCD_E2E_GIT_SERVICE=git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git
export ARGOCD_E2E_NAMESPACE=argocd-e2e
export ARGOCD_E2E_SERVER_NAME=argocd-test-server
export ARGOCD_E2E_REPO_SERVER_NAME=argocd-test-repo-server
export ARGOCD_E2E_APPLICATION_CONTROLLER_NAME=argocd-test-application-controller
export DIST_DIR=/tmp/argo-cd/dist

./e2e.test -test.v

# Test suite:
# - Connects to ArgoCD in cluster
# - Pushes test repos to git-server
# - Deploys test applications
# - Verifies ArgoCD behavior
# - Cleans up test resources
```

---

## Common Errors and Causes

### "no matches for kind ArgoCD in version argoproj.io/v1beta1"

**Cause:** Script trying to create ArgoCD CR, but:
- Not a test suite error - this is deployment script error
- Test suite doesn't create ArgoCD CR
- Our `run-argocd-e2e-tests.sh` was trying to deploy ArgoCD

**Fix:** Deploy ArgoCD before running tests, don't let test script deploy it

### "connection refused" on localhost:8080

**Cause:** ArgoCD not running or not accessible at expected address

**Fix:** Set `ARGOCD_SERVER` to correct address, ensure ArgoCD is running

### "Unauthorized" or "Invalid username/password"

**Cause:** Wrong admin credentials

**Fix:** Set `ARGOCD_E2E_ADMIN_PASSWORD` to correct password from ArgoCD secret

### Git push failures in remote mode

**Cause:** Git service not running or not accessible

**Fix:** Deploy git-server pod, set `ARGOCD_E2E_GIT_SERVICE` to correct URL

### "namespace not found: argocd-e2e"

**Cause:** Test namespace doesn't exist

**Fix:** Create namespace before running tests:
```bash
oc create namespace argocd-e2e
oc create namespace argocd-e2e-external
```

---

## Recommended Environment Variable Set

### For Standalone ArgoCD in Kubernetes

```bash
# Execution mode
export ARGOCD_E2E_REMOTE=true

# ArgoCD connection
export ARGOCD_SERVER=argocd-server.argocd-e2e.svc.cluster.local:80
export ARGOCD_SERVER_INSECURE=true
export ARGOCD_E2E_ADMIN_USERNAME=admin
export ARGOCD_E2E_ADMIN_PASSWORD=$(oc get secret argocd-initial-admin-secret -n argocd-e2e -o jsonpath='{.data.password}' | base64 -d)

# Namespaces
export ARGOCD_E2E_NAMESPACE=argocd-e2e
export ARGOCD_E2E_APP_NAMESPACE=argocd-e2e-external

# Component names (standalone uses upstream defaults)
export ARGOCD_E2E_SERVER_NAME=argocd-server
export ARGOCD_E2E_REDIS_NAME=argocd-redis
export ARGOCD_E2E_REPO_SERVER_NAME=argocd-repo-server
export ARGOCD_E2E_APPLICATION_CONTROLLER_NAME=argocd-application-controller

# Git service
export ARGOCD_E2E_GIT_SERVICE=git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git

# Working directory
export ARGOCD_E2E_DIR=/tmp/argo-e2e

# CLI binary location
export DIST_DIR=/tmp/argo-cd/dist
```

### For Operator-Deployed ArgoCD

```bash
# Execution mode
export ARGOCD_E2E_REMOTE=true

# ArgoCD connection
export ARGOCD_SERVER=argocd-test-server.argocd-e2e.svc.cluster.local:80
export ARGOCD_SERVER_INSECURE=true
export ARGOCD_E2E_ADMIN_USERNAME=admin
export ARGOCD_E2E_ADMIN_PASSWORD=$(oc get secret argocd-test-cluster -n argocd-e2e -o jsonpath='{.data.admin\.password}' | base64 -d)

# Namespaces
export ARGOCD_E2E_NAMESPACE=argocd-e2e
export ARGOCD_E2E_APP_NAMESPACE=argocd-e2e-external

# Component names (operator adds CR name prefix)
export ARGOCD_E2E_NAME_PREFIX=argocd-test
export ARGOCD_E2E_SERVER_NAME=argocd-test-server
export ARGOCD_E2E_REDIS_NAME=argocd-test-redis
export ARGOCD_E2E_REPO_SERVER_NAME=argocd-test-repo-server
export ARGOCD_E2E_APPLICATION_CONTROLLER_NAME=argocd-test-application-controller

# Git service
export ARGOCD_E2E_GIT_SERVICE=git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git

# Working directory
export ARGOCD_E2E_DIR=/tmp/argo-e2e

# CLI binary location
export DIST_DIR=/tmp/argo-cd/dist
```

---

## Key Insights for Our Implementation

### What Our Script Should Do

1. **Deploy ArgoCD** (standalone or operator) BEFORE running tests
2. **Deploy git-server** pod in `argocd-e2e` namespace
3. **Extract admin password** from ArgoCD secret
4. **Set ALL required environment variables**
5. **Run ./e2e.test** - that's it!

### What Our Script Should NOT Do

1. **Don't let tests deploy ArgoCD** - they won't
2. **Don't try to deploy ArgoCD CR in standalone mode** - causes the "no matches for kind" error
3. **Don't assume default values work** - OpenShift has different service DNS, deployment names

### Critical Environment Variables for OpenShift

These MUST be set correctly or tests will fail:

```bash
ARGOCD_E2E_REMOTE=true                    # We're running remotely
ARGOCD_SERVER=<correct-service-dns>       # Not localhost!
ARGOCD_SERVER_INSECURE=true               # Skip TLS verification
ARGOCD_E2E_ADMIN_PASSWORD=<real-password> # Not "password"
ARGOCD_E2E_GIT_SERVICE=<git-daemon-url>   # Git service must exist
ARGOCD_E2E_SERVER_NAME=<deployment-name>  # For operator: argocd-test-server
DIST_DIR=<path-to-argocd-cli>             # Must contain argocd binary
```

---

## Next Steps for Fixing Our Implementation

1. **Remove ArgoCD deployment from test script**
   - Deploy ArgoCD in a separate task/step
   - Test script just runs tests

2. **Deploy git-server as part of infrastructure**
   - Separate pod in argocd-e2e namespace
   - Exposed via Service on port 9418

3. **Set all environment variables correctly**
   - Use template from this doc
   - Adjust names for operator vs standalone

4. **Simplify test execution**
   - Just run: `cd /tmp/argo-cd/test/e2e && ../../e2e.test -test.v`
   - All setup is external

5. **Consider running tests in pod** (like downstream-CI)
   - Avoids KUBECONFIG path issues
   - More realistic networking (service DNS works)
   - Can copy test binary + fixtures into pod
