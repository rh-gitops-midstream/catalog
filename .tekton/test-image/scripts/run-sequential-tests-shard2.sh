#!/bin/bash
set -x

# Sequential ginkgo tests for the gitops-operator (shard 2 of 2).
# Env vars expected: TEST_REPO_URL, BRANCH, KUBECONFIG

# shellcheck source=./lib/load-skip-patterns.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/load-skip-patterns.sh"

export TEST_DIR="${TEST_DIR:-./test/openshift/e2e/ginkgo/sequential}"
export PROCS="${PROCS:-1}"
# Upstream gives the whole sequential suite 240m in one process. Split by file count, not
# by runtime, one shard can carry most of the slow specs: on upstream v1.22 shard 1 hit
# 120m with specs still unrun and no xks specs in it. 180m each leaves room for that.
export TIMEOUT="${TIMEOUT:-180m}"

# Shard 2 of 2: every 2nd, 4th, 6th... test file of the checked-out branch, in sorted order.
# Computed by run-e2e-tests.sh after checkout, not listed here. A fixed list is written
# against one branch: pointed at another, files it does not name run in neither shard and
# nothing reports them missing (17 of upstream v1.22's 65 sequential spec files, the first time
# this ran against it).
export GINKGO_SHARD="${GINKGO_SHARD:-2/2}"

load_ginkgo_skip_patterns /usr/local/config/skip-sequential.txt

/usr/local/bin/run-e2e-tests.sh
exit $?
