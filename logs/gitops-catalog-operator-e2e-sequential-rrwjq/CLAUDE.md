# GitOps Operator Integration Test Logs

These logs are from a Konflux pipeline that installs the GitOps operator
on an ephemeral EaaS HyperShift cluster and runs e2e tests.

## Quick diagnosis

1. **Test results**: Check `results/junit-results.xml` for pass/fail summary.
   Count failures: `grep -c 'failure message' results/junit-results.xml`

2. **Test output**: Check `tasks/test-operator/test-operator.log` for test
   stdout/stderr. Search for `FAIL` or `--- FAIL` to find failing tests.

3. **Operator install**: Check `tasks/install-operator/install-operator.log`
   for operator deployment issues.

4. **Pod health**: Check `cluster-pods/` for ArgoCD component logs.

5. **Cluster events**: Check `debug/events.txt` for scheduling, image pull,
   or crash loop issues.

## Common failure patterns

| Symptom | Where to look | Likely cause |
|---------|--------------|--------------|
| `ImagePullBackOff` in events | debug/events.txt, install-operator.log | Pull secret not propagated to HyperShift nodes |
| `exec format error` | test-operator.log | Architecture mismatch (ARM image on x86 or vice versa) |
| Test timeout (no results) | test-operator.log (last test name) | A test hung — check which test was running last |
| `FailedScheduling` | debug/events.txt | Node selector mismatch or insufficient resources |
| `MachineConfig` failures | test-operator.log | MCO not available on HyperShift — should be in skip list |
| 464/470 argo tests fail | tasks/test-operator/argocd-e2e.log | `argocd-delete` plugin missing — kubectl is wrong binary |
| `connection refused` | test-operator.log | ArgoCD server not ready or port-forward failed |

## File structure

```
logs/
├── CLAUDE.md              ← you are here
├── README.txt             ← pipeline run metadata and test summary
├── tasks/                 ← per-task stdout/stderr from pipeline steps
│   ├── install-operator/  ← operator installation output
│   └── test-operator/     ← test execution output + JUnit/JSON results
├── results/               ← copies of JUnit XML and JSON reports
├── cluster-pods/          ← pod logs from the ephemeral test cluster
└── debug/                 ← cluster state: events, resources, catalog
```

## Analysis workflow

1. Read `README.txt` for the test summary line
2. If tests failed, read the test log to identify which tests failed and why
3. If operator install failed, check install log for image pull or timeout issues
4. Cross-reference with cluster events and pod logs for infrastructure problems
5. Check if failures match known HyperShift limitations (skip list candidates)
