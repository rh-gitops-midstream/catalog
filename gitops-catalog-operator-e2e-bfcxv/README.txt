Pipeline Run Logs - gitops-catalog-operator-e2e-bfcxv
Namespace - openshift-gitops-operator
Collected - 2026-05-15 07:04:33 UTC

Test Summary: Tests: 116 total, 114 passed, 0 failed, 2 skipped, 0 errors

Structure:
  - tasks/         : stdout/stderr from each pipeline task step
  - results/       : test result files (JUnit XML, JSON reports)
  - cluster-pods/  : pod logs from the ephemeral cluster
  - debug/         : cluster and namespace debug information

Files:
  - logs/README.txt
  - logs/cluster-pods/01-openshift-gitops-operator-controller-manager-64b9464bfb-5dfxs.log
  - logs/debug/catalogsource.txt
  - logs/debug/cluster-info.txt
  - logs/debug/events.txt
  - logs/debug/namespace-resources.txt
  - logs/results/junit-results.xml
  - logs/results/test-results.json
  - logs/tasks/install-operator/install-operator-logs/env.sh
  - logs/tasks/install-operator/install-operator-logs/install-operator.log
  - logs/tasks/install-operator/install-operator-logs/kubeconfig
  - logs/tasks/install-operator/install-operator-logs/reproduce.sh
  - logs/tasks/test-operator/test-operator-logs/env.sh
  - logs/tasks/test-operator/test-operator-logs/junit-results.xml
  - logs/tasks/test-operator/test-operator-logs/kubeconfig
  - logs/tasks/test-operator/test-operator-logs/reproduce.sh
  - logs/tasks/test-operator/test-operator-logs/test-operator.log
  - logs/tasks/test-operator/test-operator-logs/test-results.json
  - logs/tasks/upgrade-operator/upgrade-operator-logs/env.sh
  - logs/tasks/upgrade-operator/upgrade-operator-logs/kubeconfig
  - logs/tasks/upgrade-operator/upgrade-operator-logs/reproduce.sh
  - logs/tasks/upgrade-operator/upgrade-operator-logs/upgrade-operator.log

Collection warnings:
  - Could not pull logs for task logs (may not have uploaded)

To extract these logs:
  oras pull quay.io/devtools_gitops/test_image:gitops-catalog-operator-e2e-bfcxv-logs
  tar xzf gitops-catalog-operator-e2e-bfcxv-logs.tar.gz
