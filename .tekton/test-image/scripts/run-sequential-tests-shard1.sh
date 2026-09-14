#!/bin/bash
set -x

# Sequential ginkgo tests for the gitops-operator (shard 1 of 2).
# Env vars expected: TEST_REPO_URL, BRANCH, KUBECONFIG

# shellcheck source=./lib/load-skip-patterns.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/load-skip-patterns.sh"

export TEST_DIR="${TEST_DIR:-./test/openshift/e2e/ginkgo/sequential}"
export PROCS="${PROCS:-1}"
export TIMEOUT="${TIMEOUT:-120m}"

# Shard 1 of 2: every 1st, 3rd, 5th... test file of the checked-out branch, in sorted order.
# Computed by run-e2e-tests.sh after checkout, not listed here. A fixed list is written
# against one branch: pointed at another, files it does not name run in neither shard and
# nothing reports them missing (17 of upstream v1.22's 65 sequential spec files, the first time
# this ran against it).
export GINKGO_SHARD="${GINKGO_SHARD:-1/2}"

load_ginkgo_skip_patterns /usr/local/config/skip-sequential.txt

/usr/local/bin/run-e2e-tests.sh
exit $?
