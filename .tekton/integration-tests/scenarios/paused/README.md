# Paused scenarios

These IntegrationTestScenarios are not applied to the tenant. They are kept so they can be
brought back unchanged, not deleted.

Paused on 2026-10-12, to get the release tier reliable against one configuration first:
the newest standard OpenShift, on the `gcp-422` Hive pool. The scenarios in the parent
directory are the ones that run.

| Scenario | Why it is here |
|---|---|
| `gitops-catalog-sanity-1-19`, `-1-20`, `-1-21` | Sanity tier, paused with the rest |
| `gitops-catalog-nightly-1-19`, `-1-20`, `-1-21` | Nightly tier, paused with the rest |
| `gitops-catalog-release-1-21-ocp420`, `gitops-catalog-release-1-22-ocp420` | Release tier on the oldest supported OpenShift; there is no 4.20 pool at the moment |

All eight point at `pool-2`, the 4.20 pool, which is being retired. None of them will work
as written once it is gone.

## A file here does nothing by itself

Scenarios are applied by hand, so moving a file does not stop a scenario that is already
on the cluster. To actually pause them:

```
oc delete integrationtestscenario -n rh-openshift-gitops-tenant \
  gitops-catalog-sanity-1-19 gitops-catalog-sanity-1-20 gitops-catalog-sanity-1-21 \
  gitops-catalog-nightly-1-19 gitops-catalog-nightly-1-20 gitops-catalog-nightly-1-21 \
  gitops-catalog-release-1-21-ocp420 gitops-catalog-release-1-22-ocp420
```

Until that is done they keep firing on every build and claiming clusters.

## Bringing one back

1. Give it a pool that exists. For the 4.20 scenarios that means a new pool first
   (`gcp-420`, by the naming in hive-ops), with its own `hive-hub-kubeconfig-<pool>` secret.
   Set `POOL_NAME`, `POOL_NAMESPACE` and `HIVE_HUB_SECRET` together; they must agree.
2. For a release scenario, copy the `LEGS` split and the timeout annotations from a
   scenario in the parent directory, so the versions are compared on the same cut.
3. Move the file back up a directory and `oc apply` it.
