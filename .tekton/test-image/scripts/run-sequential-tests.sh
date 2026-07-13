#!/bin/bash
set -x

# Sequential ginkgo tests for the gitops-operator.
# Env vars expected: TEST_REPO_URL, BRANCH, KUBECONFIG

# shellcheck source=./lib/load-skip-patterns.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/load-skip-patterns.sh"

export TEST_DIR="${TEST_DIR:-./test/openshift/e2e/ginkgo/sequential}"
export PROCS="${PROCS:-1}"
export TIMEOUT="${TIMEOUT:-240m}"

load_ginkgo_skip_patterns /usr/local/config/skip-sequential.txt

/usr/local/bin/run-e2e-tests.sh
exit $?
