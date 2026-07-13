# Integration Tests

This directory contains the Konflux integration test infrastructure for the GitOps operator. Tests run on ephemeral HyperShift clusters provisioned by EaaS (Ephemeral-as-a-Service) and exercise the operator installed via OLM from a real FBC catalog image.

---

## Directory Layout

```
.tekton/
├── integration-tests/
│   ├── pipelines/                          # Tekton Pipeline definitions
│   │   ├── catalog-gitops-operator-e2e.yaml  # Main operator e2e pipeline
│   │   ├── catalog-argocd-e2e.yaml           # Upstream ArgoCD e2e pipeline
│   │   └── catalog-gitops-operator-dast.yaml # DAST (ZAP) pipeline
│   └── scenarios/                          # IntegrationTestScenario CRs (one file per channel)
│       ├── gitops-operator-tests.yaml      # latest channel (current dev)
│       ├── gitops-sanity-tests.yaml        # latest channel sanity only
│       ├── gitops-ui-tests.yaml            # latest channel UI only
│       ├── gitops-channel-tests-1-21.yaml  # gitops-1.21 channel
│       ├── gitops-channel-tests-1-20.yaml  # gitops-1.20 channel
│       ├── gitops-channel-tests-1-19.yaml  # gitops-1.19 channel
│       ├── gitops-argocd-tests.yaml        # ArgoCD upstream e2e
│       └── gitops-dast.yaml               # DAST scan
├── stepactions/
│   ├── check-gate-labels.yaml             # Gate-label check before running tests
│   ├── resolve-openshift-version.yaml     # Resolve latest patch for an OCP minor version
│   └── extract-image-content-sources.yaml # Extract ImageContentSourcePolicy from catalog
├── tasks/
│   ├── build-ginkgo-test-image.yaml       # Build the base test image from Dockerfile
│   ├── overlay-test-scripts.yaml          # Overlay current scripts onto the built image
│   ├── provision-cluster.yaml             # Provision HyperShift cluster via EaaS
│   ├── install-operator.yaml              # Install gitops-operator via OLM
│   ├── test-operator.yaml                 # Run e2e test suite
│   ├── pipeline-wrapup.yaml               # Upload logs, publish results, send Slack
│   ├── deploy-argocd.yaml                 # Deploy standalone ArgoCD (ArgoCD e2e only)
│   ├── extract-argocd-image.yaml          # Extract ArgoCD image ref from catalog FBC
│   ├── generate-catalog.yaml              # Generate FBC catalog from bundle images
│   ├── test-argocd.yaml                   # Run ArgoCD upstream e2e
│   └── test-dast.yaml                     # Run RapidAST/ZAP scan
└── test-image/                            # Test image source — see below
```

---

## How a Test Run Works

Every integration test follows the same pipeline steps:

```
check-gate-labels
      │
      ▼
build-test-image ──► overlay-test-scripts
                              │
                              ▼
                     provision-eaas-space
                              │
                              ▼
                     provision-cluster  (HyperShift on AWS)
                              │
                              ▼
                     install-operator   (OLM + FBC catalog image)
                              │
                              ▼
                     test-operator      (Ginkgo test suite in a pod)
                              │
                              ▼ (always, via finally)
                     pipeline-wrapup    (upload logs to Quay, publish results, Slack)
```

### Step 1 — Gate check

`check-gate-labels` reads the GitHub API to find the PR that introduced the commit being tested. If `GATE_LABEL` is non-empty, the PR must carry that label for the rest of the pipeline to run. This prevents expensive cluster provisioning on every push.

### Step 2 — Build test image

The test image is built in two stages on every run:

1. **`build-test-image`** — builds from `Dockerfile` in the catalog repo. This layer contains all scripts and config files. It uses the pre-built base image (heavy tools, Go toolchain, pre-compiled test binaries) as its `FROM`.
2. **`overlay-test-scripts`** — overlays the *current branch's* scripts on top of the built image. This means any script change in the catalog repo is live in the test immediately — no need to rebuild the base image.

### Step 3 — Cluster provisioning

`provision-cluster` requests an ephemeral HyperShift cluster from EaaS. The cluster runs on AWS with the requested OCP version and instance type (default `m6g.large`). The task waits until the cluster API is reachable and writes a kubeconfig to a shared workspace.

### Step 4 — Operator installation

`install-operator` generates a CatalogSource from the FBC image under test, creates an OLM Subscription, and waits for the CSV to reach `Succeeded`. It also patches pull secrets into all relevant service accounts so the cluster can pull Red Hat registry images.

If `UPGRADE=true`, the task installs the *previous channel* first and then patches the Subscription to the target channel, triggering an upgrade.

### Step 5 — Test execution

`test-operator` launches a pod on the cluster running the test image. The pod runs `run-and-save-logs.sh` which invokes the appropriate test script (e.g. `run-e2e-tests.sh`) and streams output to the sidecar log collector. Test results are written to `${RESULTS_DIR}` as JUnit XML.

### Step 6 — Wrapup (always runs)

`pipeline-wrapup` always runs regardless of test outcome:
- Pulls per-task log artifacts from Quay (pushed by each task's sidecar)
- Collects cluster logs (operator logs, events, pod descriptions)
- Parses JUnit XML into a JSON summary
- Pushes the combined log bundle to Quay as a single `<pipelinerun>-logs` artifact
- Publishes the JSON summary to the `catalog-results` git repo
- Sends a Slack notification with pass/fail counts and a link to the logs

---

## Test Suites

### Gitops Operator Ginkgo Tests

The main test suite lives in [rh-gitops-release-qa/gitops-operator](https://github.com/rh-gitops-release-qa/gitops-operator) — a QA fork of the upstream repo that contains downstream-specific fixes (image check adaptations, OCP guided tour workarounds, etc.).

| Script | What it runs | Split |
|--------|-------------|-------|
| `run-sanity-tests.sh` | A curated fast subset — smoke/sanity check | Single shard |
| `run-sequential-tests-shard1.sh` | Sequential e2e tests, first half | Shard 1 of 2 |
| `run-sequential-tests-shard2.sh` | Sequential e2e tests, second half | Shard 2 of 2 |
| `run-parallel-tests.sh` | Parallel e2e tests | Single shard |
| `run-sequential-tests.sh` | Full sequential suite (un-sharded, used for quick local runs) | Single shard |
| `run-rollouts-tests.sh` | Argo Rollouts integration tests | Single shard |
| `run-ui-e2e-tests.sh` | Playwright browser tests against the OCP console | Single shard |

All scripts ultimately call `run-e2e-tests.sh` (except UI), which:
1. Fetches the QA fork branch (`TEST_REPO_URL` / `TEST_REPO_BRANCH`)
2. Runs the pre-compiled Ginkgo binary from `/testsuites/gitops-operator/`
3. Applies skip patterns from `config/skip-*.txt`

#### QA Fork Branches

| Channel | Upstream branch | QA fork branch |
|---------|----------------|----------------|
| latest | master | `konflux-integration-latest` |
| gitops-1.21 | v1.21 | `konflux-integration-1.21` |
| gitops-1.20 | v1.20 | `konflux-integration-1.20` |
| gitops-1.19 | v1.19 | `konflux-integration-1.19` |

The QA fork branches carry patches that make tests pass against the downstream operator:
- Relaxed image assertions (downstream uses `registry.redhat.io/openshift-gitops-1/` images, not upstream `quay.io/argoprojlabs/` images)
- OCP guided tour dialog dismissal in the Playwright setup

### ArgoCD Upstream E2E

`run-argocd-e2e-tests.sh` runs the upstream ArgoCD test suite against a standalone ArgoCD deployment (not the operator). It uses a pre-compiled `e2e.test` binary for ArgoCD v2.14 — other versions are compiled from source at runtime (~10-15 min penalty).

### UI E2E (Playwright)

`run-ui-e2e-tests.sh` runs Playwright browser tests against the OpenShift console with the GitOps plugin. The tests authenticate as kubeadmin; the auth setup (`.auth/setup.ts`) includes logic to dismiss the OCP "guided tour" dialog that appears after first login.

### DAST

The DAST pipeline uses RapidAST/ZAP to scan the ArgoCD REST API for security vulnerabilities. False-positive suppression rules live in `config/dast-false-positives.json`.

---

## The Test Image

### Three-Layer Architecture

The test image is split into three layers to avoid rebuilding slow layers on every script change:

```
Dockerfile.base-v1.21      (Rebuild: rarely — tools or Go version change)
        │
        ▼
Dockerfile.testsuites      (Rebuild: when test binaries or Go deps change)
        │
        ▼
Dockerfile                 (Rebuild: every push — scripts and configs)
```

**Layer 1 — Base** (`Dockerfile.base-v1.21`)

Heavy dependencies: UBI9, `oc` CLI, `jq`, `yq`, `git`, `skopeo`, `oras`, Go toolchain, Node.js. Takes ~15-20 minutes to build.

**Rebuild when:**
- Go version changes
- `oc` / `oras` / `yq` version changes
- New system packages are needed

**Layer 2 — Testsuites** (`Dockerfile.testsuites`)

Pre-compiled Ginkgo test binaries for the gitops-operator test suite and ArgoCD e2e binary. Clones the test repo and runs `ginkgo build`.

**Rebuild when:**
- A new operator channel is added
- Go module dependencies change significantly
- You want to pre-bake a new ArgoCD e2e binary version

**Layer 3 — Final** (`Dockerfile`)

Copies all scripts from `scripts/` and config from `config/`. This layer is rebuilt by `build-test-image` on every pipeline run (fast — no compilation).

**Rebuilt automatically** on every run via the pipeline. No manual action needed for script-only changes.

### Building the Base Image Manually

When you need to rebuild the base or testsuites layer:

```bash
cd .tekton/test-image

# Layer 1 — base tools
podman build -f Dockerfile.base-v1.21 \
  -t quay.io/devtools_gitops/test_image:base-v1.21 .

# Layer 2 — pre-compiled test binaries
podman build -f Dockerfile.testsuites \
  --build-arg BASE_IMAGE=quay.io/devtools_gitops/test_image:base-v1.21 \
  -t quay.io/devtools_gitops/test_image:testsuites .

# Push both
podman push quay.io/devtools_gitops/test_image:base-v1.21
podman push quay.io/devtools_gitops/test_image:testsuites
```

Then update the `FROM` reference in `Dockerfile` to match the new base tag.

The `build-and-push.sh` script automates this:
```bash
bash .tekton/test-image/build-and-push.sh
```

---

## Log Storage (Quay / ORAS)

Test artifacts are stored in [quay.io/devtools_gitops/test_image](https://quay.io/devtools_gitops/test_image) as OCI artifacts using ORAS tags.

### Per-Task Logs (sidecar)

Each task (install-operator, test-operator) runs a `collect-logs-sidecar.sh` sidecar container that watches the task's working directory and incrementally pushes log snapshots to Quay as:

```
quay.io/devtools_gitops/test_image:<pipelinerun-name>-<taskname>-logs
```

### Combined Log Bundle (wrapup)

After all tasks complete, `collect-and-upload-logs.sh` pulls every task's log artifact, merges them with cluster-level logs (operator logs, events, pod descriptions), and pushes a single bundle:

```
quay.io/devtools_gitops/test_image:<pipelinerun-name>-logs
```

### Pulling Logs Locally

```bash
# Pull the combined log bundle for a pipeline run
oras pull quay.io/devtools_gitops/test_image:<pipelinerun-name>-logs

# Or just the test task logs
oras pull quay.io/devtools_gitops/test_image:<pipelinerun-name>-test-operator-logs
```

Artifacts expire after **7 days** (set via the `IMAGE_EXPIRES_AFTER` label on the ORAS push).

---

## Results Storage (catalog-results)

Pass/fail summaries are published to a separate git repository: `rh-gitops-midstream/catalog-results`.

`publish-results.sh` clones this repo, calls `render-results.py` to update README files, and pushes the commit. The repo renders as a browsable dashboard at its GitHub URL.

### Directory Structure

```
catalog-results/
└── gitops-operator/
    └── v1.21.1/
        └── ocp-4.20/
            ├── README.md         # Human-readable summary table
            └── results.jsonl     # Machine-readable: one JSON record per run
```

Each `results.jsonl` line contains:
- Pipeline run name and timestamp
- Test script name (`testScript`)
- Operator channel and OCP version
- Pass/fail/skip counts from JUnit XML
- Link to the Quay log artifact

### Results JSON Format

```json
{
  "pipelineRunName": "catalog-4-20-abc123-test-operator",
  "timestamp": "2026-06-25T10:30:00Z",
  "product": "gitops-operator",
  "version": "v1.21.1",
  "ocp": "4.20",
  "variant": "default",
  "testScript": "run-sequential-tests-shard1.sh",
  "result": "SUCCESS",
  "successes": 23,
  "failures": 0,
  "warnings": 0
}
```

---

## Skip Lists

Test skip patterns live in `test-image/config/`:

| File | Applies to |
|------|-----------|
| `skip-sequential.txt` | Sequential Ginkgo tests (both shards) |
| `skip-parallel.txt` | Parallel Ginkgo tests |
| `skip-ui-e2e.txt` | Playwright UI tests |
| `skip-argocd.txt` | ArgoCD upstream e2e |

Format: one Ginkgo pattern per line, regex supported, `#` for comments. Patterns are passed as `--label-filter` or `--skip` flags to the test runner.

To skip a test globally (e.g. flaky on HyperShift):
```
# skip-sequential.txt
1-053_validate_argocd_agent_principal_connected  # requires a running principal server
```

---

## Script Reference

### Test Runner Scripts

| Script | Purpose |
|--------|---------|
| `run-e2e-tests.sh` | Core runner: fetches the QA fork branch, runs a pre-compiled Ginkgo binary with the supplied args |
| `run-sanity-tests.sh` | Sanity/smoke subset; calls `run-e2e-tests.sh` |
| `run-sequential-tests-shard1.sh` | Sequential shard 1 — focus list of ~23 test files |
| `run-sequential-tests-shard2.sh` | Sequential shard 2 — focus list of ~20 test files |
| `run-parallel-tests.sh` | Full parallel suite |
| `run-rollouts-tests.sh` | Argo Rollouts tests |
| `run-ui-e2e-tests.sh` | Playwright browser tests; installs Node deps and Chromium at runtime |
| `run-argocd-e2e-tests.sh` | Upstream ArgoCD e2e; uses pre-built binary for v2.14, compiles from source otherwise |
| `run-argocd-e2e-tests-in-pod.sh` | Wrapper that runs the ArgoCD e2e suite inside a pod on the cluster |
| `run-argocd-e2e-full.sh` | End-to-end ArgoCD test orchestrator (deploy + run + cleanup) |

### Operator Lifecycle Scripts

| Script | Purpose |
|--------|---------|
| `install-operator.sh` | Installs or upgrades the operator via OLM; patches pull secrets; waits for CSV |
| `upgrade-operator.sh` | Patches Subscription channel and waits for the new CSV |
| `deploy-argocd-standalone.sh` | Deploys standalone ArgoCD (no operator) for ArgoCD e2e |

### Log and Results Scripts

| Script | Purpose |
|--------|---------|
| `run-and-save-logs.sh` | Wrapper that runs a test script and collects output; used as the task entrypoint |
| `collect-logs-sidecar.sh` | Sidecar: incrementally pushes task logs to Quay during the run |
| `collect-and-upload-logs.sh` | Wrapup: merges all task logs with cluster logs and uploads the bundle |
| `collect-build-metadata.sh` | Collects installed component versions (ArgoCD, Helm, etc.) into a JSON file |
| `parse-test-results.py` | Parses JUnit XML into the results JSON format |
| `parse-dast-results.py` | Parses RapidAST/ZAP output into the results JSON format |
| `publish-results.sh` | Commits and pushes the results JSON to the catalog-results repo |
| `render-results.py` | Re-renders all README files in catalog-results from the JSONL data |
| `send-slack-message.py` | Sends pass/fail Slack notification with log links |
| `print-cluster-login-info.sh` | Prints `oc login` command (password redacted) to aid manual debugging |
| `get-installed-version.sh` | Reports the installed operator version from the cluster |
| `go-cache.sh` | Manages a Go build cache between runs (pull/push to ORAS artifact store) |
| `verify-images.py` | Verifies that deployed component images match expected digest/registry |
| `extract-argocd-image-from-catalog.py` | Parses an FBC catalog to find the ArgoCD component image reference |
| `deploy-test-runner-pod.sh` | Launches the test pod on the target cluster |
| `deploy-e2e-server.sh` | Deploys an ArgoCD e2e server component for the upstream e2e suite |
| `cleanup-argocd-e2e.sh` | Tears down ArgoCD e2e test resources after the run |

### Library Scripts (`lib/`)

| Script | Purpose |
|--------|---------|
| `lib/wait-for-resources.sh` | `wait_for_csv`, `wait_for_deployment`, etc. — shared polling helpers |
| `lib/oras-helpers.sh` | `oras_push_tarball`, `oras_pull_tarball` — wraps ORAS with auth and retry |
| `lib/collect-pod-logs.sh` | Fetches logs from all pods in a namespace |
| `lib/load-skip-patterns.sh` | Reads a skip file and emits the appropriate Ginkgo flags |
| `lib/argocd-e2e-cleanup.sh` | Shared cleanup logic for ArgoCD e2e test resources |

---

## Adding a New Channel

To add tests for a new operator channel (e.g. `gitops-1.22`):

1. **Create a QA fork branch** in `rh-gitops-release-qa/gitops-operator`:
   ```bash
   git checkout -b konflux-integration-1.22 upstream/v1.22
   # Apply any downstream fixes needed
   git push origin konflux-integration-1.22
   ```

2. **Create a scenario file** by copying the nearest channel file:
   ```bash
   cp .tekton/integration-tests/scenarios/gitops-channel-tests-1-21.yaml \
      .tekton/integration-tests/scenarios/gitops-channel-tests-1-22.yaml
   ```
   Update all occurrences of `1-21`, `v1.21`, `gitops-1.21`, `gitops-1.20` (upgrade from), and `konflux-integration-1.21` to their 1.22 equivalents.

3. **Register the scenario** in Konflux by applying the new file:
   ```bash
   oc apply -f .tekton/integration-tests/scenarios/gitops-channel-tests-1-22.yaml
   ```

4. **Rebuild the testsuites layer** if the new branch has different Go dependencies or you want a pre-compiled binary for it.

---

## Common Debugging Steps

**View logs for a failed run:**
```bash
oras pull quay.io/devtools_gitops/test_image:<pipelinerun>-logs
# Logs land in ./logs/
ls logs/
```

**Re-run a specific scenario manually** (from the cluster where Konflux is running):
```bash
oc create -f - <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
# ... (copy from an existing run and adjust params)
EOF
```

**Check the results dashboard:**
Browse `https://github.com/rh-gitops-midstream/catalog-results` — each OCP version has a `README.md` with a status table.
