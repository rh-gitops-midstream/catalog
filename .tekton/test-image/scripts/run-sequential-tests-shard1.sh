#!/bin/bash
set -x

# Sequential ginkgo tests for the gitops-operator (shard 1 of 2).
# Env vars expected: TEST_REPO_URL, BRANCH, KUBECONFIG

# shellcheck source=./lib/load-skip-patterns.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/load-skip-patterns.sh"

export TEST_DIR="${TEST_DIR:-./test/openshift/e2e/ginkgo/sequential}"
export PROCS="${PROCS:-1}"
export TIMEOUT="${TIMEOUT:-120m}"

# Focus on odd-numbered test files (1st, 3rd, 5th, etc.)
export GINKGO_FOCUS_FILE="1-002-validate_backend_service_test.go|1-004_validate_argocd_installation_test.go|1-008_validate-4.9CI-Failures_test.go|1-018_validate_disable_default_instance_test.go|1-026-validate_backend_service_permissions_test.go|1-028-validate_run_on_infra_test.go|1-035_validate_argocd_secret_repopulate_test.go|1-037_validate_applicationset_in_any_namespace_test.go|1-051_validate_argocd_agent_principal_test.go|1-052_validate_rolebinding_number_test.go|1-056_validate_managed-by_test.go|1-064_validate_tcp_reset_error_test.go|1-071_validate_SCC_HA_test.go|1-077_validate_disable_dex_removed_test.go|1-083_validate_apps_in_any_namespace_test.go|1-086_validate_default_argocd_role_test.go|1-101_validate_rollout_policyrules_test.go|1-103-validate-rollouts-imagepullpolicy.go|1-105_validate_label_selector_test.go|1-107_validate_redis_scc_test.go|1-110_validate_podsecurity_alerts_test.go|1-112_validate_rollout_plugin_support_test.go|1-114_validate_imagepullpolicy_test.go|1-120_repo_server_system_ca_trust.go|1-121-valiate_resource_constraints_gitopsservice_test.go|1-123_validate_list_order_comparison_test.go"

load_ginkgo_skip_patterns /usr/local/config/skip-sequential.txt

/usr/local/bin/run-e2e-tests.sh
exit $?
