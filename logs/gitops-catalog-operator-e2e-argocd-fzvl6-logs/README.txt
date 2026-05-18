Pipeline Run Logs - gitops-catalog-operator-e2e-argocd-fzvl6
Namespace - openshift-gitops-operator
Collected - 2026-05-06 07:26:27 UTC

Structure:
  - tasks/         : stdout/stderr from each pipeline task step
  - results/       : test result files (JUnit XML, JSON reports)
  - cluster-pods/  : pod logs from the ephemeral cluster
  - debug/         : cluster and namespace debug information

Files:
  - logs/README.txt
  - logs/tasks/install-operator/install-operator.log
  - logs/tasks/test-operator/application-controller.log
  - logs/tasks/test-operator/applicationset-controller.log
  - logs/tasks/test-operator/argocd-e2e.log
  - logs/tasks/test-operator/argocd-test-server.log
  - logs/tasks/test-operator/test-operator.log

Collection warnings:
  - Could not pull logs for task upgrade-operator (may not have uploaded)
  - Could not pull logs for task logs (may not have uploaded)
  - Kubeconfig not available (file: unset)

To extract these logs:
  oras pull quay.io/devtools_gitops/test_image:gitops-catalog-operator-e2e-argocd-fzvl6-logs
  tar xzf combined-logs.tar.gz
