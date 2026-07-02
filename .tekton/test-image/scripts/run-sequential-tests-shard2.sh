#!/bin/bash
set -x

# Sequential ginkgo tests for the gitops-operator (shard 2 of 2).
# Env vars expected: TEST_REPO_URL, BRANCH, KUBECONFIG

# shellcheck source=./lib/load-skip-patterns.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/load-skip-patterns.sh"

export TEST_DIR="${TEST_DIR:-./test/openshift/e2e/ginkgo/sequential}"
export PROCS="${PROCS:-1}"
export TIMEOUT="${TIMEOUT:-120m}"

# Focus on even-numbered test files (2nd, 4th, 6th, etc.)
export GINKGO_FOCUS_FILE="1-003_validate_cluster_config_test.go|1-006_validate_machine_config_test.go|1-010_validate-ootb-manage-other-namespace_test.go|1-020_validate_redis_ha_nonha_test.go|1-027_validate_operand_from_git_test.go|1-034_validate_custom_roles_test.go|1-036_validate_role_rolebinding_for_source_namespace_test.go|1-040_validate_quoted_RBAC_group_names_test.go|1-052_validate_argocd_agent_agent_test.go|1-053_validate_argocd_agent_principal_connected_test.go|1-058_validate_notifications_source_namespaces_test.go|1-071_validate_node_selectors_test.go|1-074_validate_terminating_namespace_block_test.go|1-078_validate_default_argocd_consoleLink_test.go|1-085_validate_dynamic_plugin_installation_test.go|1-100_validate_rollouts_resources_creation_test.go|1-102_validate_handle_terminating_namespaces_test.go|1-105_validate_default_argocd_route_test.go|1-106_validate_argocd_metrics_controller_test.go|1-108_alternate_cluster_roles_cluster_scoped_instance_test.go|1-111_validate_default_argocd_route_test.go|1-113_validate_namespacemanagement_test.go|1-115_validate_imagepullpolicy_console_plugin_test.go|1-120_validate_running_must_gather.go|1-122_validate_namespace_test.go|suite_test.go"

load_ginkgo_skip_patterns /usr/local/config/skip-sequential.txt

/usr/local/bin/run-e2e-tests.sh
exit $?
