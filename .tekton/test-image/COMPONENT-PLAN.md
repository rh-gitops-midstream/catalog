# Test Image Konflux Component Plan

**Status:** Blocked — wait for current release to complete before creating.

## Goal

Replace manual `build-and-push.sh` runs with an automatic Konflux component that builds the test runner image on push. Contributors update scripts or Dockerfiles in a PR and the pipeline transparently picks up the new image from the snapshot.

## Component Definition

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: Component
metadata:
  name: gitops-test-runner
  namespace: rh-openshift-gitops-tenant
spec:
  application: catalog-4-20
  componentName: gitops-test-runner
  containerImage: quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-test-runner
  source:
    git:
      url: https://github.com/rh-gitops-midstream/catalog.git
      revision: main
      context: .tekton/test-image
      dockerfileUrl: Dockerfile
```

## Merged Multi-Stage Dockerfile

Collapse the current 3-layer build (`Dockerfile.base` / `Dockerfile.testsuites` / `Dockerfile`) into a single multi-stage Dockerfile for automatic layer caching:

```
Stage 1: base        — UBI9, dnf packages, oc, oras, yq     (changes: rarely)
Stage 2: testsuites  — git clone + ginkgo build + argocd     (changes: version bumps)
Stage 3: final       — node.js, COPY scripts/, COPY config/  (changes: frequently)
```

### Cache behavior

| What changed              | Cached stages      | Rebuild cost |
|---------------------------|--------------------|--------------|
| `scripts/` or `config/`  | base + testsuites  | ~1 min       |
| Dockerfile test versions  | base               | ~15 min      |
| Dockerfile base tools     | nothing            | ~20 min      |

Requires `--cache-from` pointing to the previous image so Buildah reuses layers across builds.

## Pipeline Integration

Two options for how e2e pipelines consume the image:

1. **Snapshot-based** (preferred): The test image component is part of the same application as the catalog. When a snapshot is created, the e2e IntegrationTestScenarios receive a SNAPSHOT containing both the catalog image and the test runner image. The pipeline extracts the test runner image from the snapshot instead of using a hardcoded `TEST_IMAGE_URL`.

2. **Default parameter**: Keep the current `TEST_IMAGE_URL` pipeline parameter and update its default whenever the test image is rebuilt. Simpler but requires manual default updates.

## Prerequisites

- [ ] Release in progress must complete
- [ ] `konflux-integration` branch pushed to `rh-gitops-midstream/catalog`
- [ ] Merged multi-stage Dockerfile created and tested locally
- [ ] Verify `--cache-from` works with `docker-build-oci-ta` pipeline
- [ ] Create Application + Component resources on cluster
- [ ] Update IntegrationTestScenarios to consume image from snapshot (if using option 1)

## Files

- `Dockerfile` — replace with merged multi-stage version
- `Dockerfile.base` — keep for local `build-and-push.sh` fallback, or remove
- `Dockerfile.testsuites` — same as above
- `build-and-push.sh` — keep as local dev fallback, or remove once component is working
