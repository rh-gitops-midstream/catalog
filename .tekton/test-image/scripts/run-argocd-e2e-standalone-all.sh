#!/bin/bash
# The standalone Argo CD e2e leg with nothing skipped.
#
# run-argocd-e2e-standalone.sh applies config/skip-argocd.txt (154 of 512 top-level tests in
# v3.5.2), three built-in skips, and the fixture's GPG and OPENSHIFT env skips. That list was
# collected from release-pipeline runs on EaaS HyperShift clusters, so on a regular OpenShift
# cluster it can hide tests that pass. This leg turns all of it off to measure the whole
# suite. Tests the list excluded for crashing the binary are handled by the runner's
# resume-after-crash loop, which gets a higher retry budget here.
set -euo pipefail
export ARGOCD_E2E_USE_SKIP_LIST=false
export ARGOCD_E2E_SKIP_GPG=false
export ARGOCD_E2E_SKIP_OPENSHIFT=false
export ARGOCD_E2E_MAX_CRASH_RETRIES="${ARGOCD_E2E_MAX_CRASH_RETRIES:-60}"
# About 150 more tests than the filtered run, which took ~1h of test time; leave room.
export ARGOCD_E2E_TEST_TIMEOUT="${ARGOCD_E2E_TEST_TIMEOUT:-5h}"
exec "$(dirname "${BASH_SOURCE[0]}")/run-argocd-e2e-standalone.sh"
