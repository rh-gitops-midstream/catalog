#!/bin/bash
# Upgrade baseline: installs the previous version of the operator, configures it, checks
# every configured feature, upgrades to the version under test, and checks them again --
# the Ginkgo suite in test/openshift/e2e/ginkgo/upgrade (rh-gitops-release-qa/gitops-operator
# PR #2). Afterwards it removes the suite's fixture but keeps the upgraded operator, so the
# suites listed after it in the same leg run against an upgraded installation instead of a
# clean one.
#
# Used as the first suite of a leg, with the upgrade source after colons:
#
#   run-upgrade-baseline.sh:gitops-1.20:1.20.8   from exactly 1.20.8 in gitops-1.20
#   run-upgrade-baseline.sh:gitops-1.19          from the head of gitops-1.19
#
# hive-suite-leg sees that form, has install-operator.sh only create the catalog under test
# (the suite refuses a cluster with the operator already installed), and passes the source
# here as UPGRADE_FROM_CHANNEL and UPGRADE_FROM_VERSION. The target is the leg's own channel
# (OPERATOR_CHANNEL) and, if pinned, OPERATOR_VERSION; unpinned it is that channel's head in
# the catalog under test -- the release candidate.
#
# Env: UPGRADE_FROM_CHANNEL, UPGRADE_FROM_VERSION (optional), OPERATOR_CHANNEL,
#      OPERATOR_VERSION (optional), TEST_REPO_URL, KUBECONFIG
#      UPGRADE_TEST_BRANCH (optional; the branch carrying the suite)
set -uo pipefail

: "${UPGRADE_FROM_CHANNEL:?run-upgrade-baseline.sh needs a source: run-upgrade-baseline.sh:<channel>[:<version>]}"
: "${OPERATOR_CHANNEL:?OPERATOR_CHANNEL is the channel to upgrade to}"

export PREVIOUS_CHANNEL="$UPGRADE_FROM_CHANNEL"
export PREVIOUS_VERSION="${UPGRADE_FROM_VERSION:-}"
export NEW_CHANNEL="$OPERATOR_CHANNEL"
export NEW_VERSION="${OPERATOR_VERSION:-}"
# The CatalogSource install-operator.sh created from the Snapshot's catalog. Both the
# source and the target must be in it; the RC catalogs carry every released version.
export CATALOG_SOURCE=gitops-stage

# The name install-operator.sh gives the Subscription. In CI mode the e2e fixture finds the
# Subscription by the prefix gitops-operator-, so under the suite's default name
# (openshift-gitops-operator) every suite after this one found none: 17 sequential and 2
# parallel specs failed at fixture.go:456 on the first 1.20.9 upgrade run.
export SUBSCRIPTION_NAME=gitops-operator-konflux

# The suite is not on the konflux-integration-* branches yet; it lives on its own branch
# of the QA fork, based on upstream master, and is independent of the operator version
# under test: it drives OLM and checks CRs, it does not import operator code.
export BRANCH="${UPGRADE_TEST_BRANCH:-poc/upgrade-suite}"
export TEST_DIR=./test/openshift/e2e/ginkgo/upgrade
# Ordered and stateful: one process, never parallel.
export PROCS=1
export TIMEOUT=90m
unset GINKGO_SKIP GINKGO_FOCUS_FILE

echo "upgrade baseline: ${PREVIOUS_CHANNEL}${PREVIOUS_VERSION:+ @ $PREVIOUS_VERSION}" \
     "-> ${NEW_CHANNEL}${NEW_VERSION:+ @ $NEW_VERSION}, suite from ${BRANCH}"

/usr/local/bin/run-e2e-tests.sh
rc=$?

# The suite approves InstallPlans by hand, so the Subscription is left on Manual approval.
# The suites that follow expect what install-operator.sh sets up -- Automatic -- and some
# change the Subscription's config, which must not wait for an approval nobody gives.
oc patch subscription "$SUBSCRIPTION_NAME" -n openshift-gitops-operator --type merge \
  -p '{"spec":{"installPlanApproval":"Automatic"}}' || true

# Take away what the suite added, so the next suites start from an upgraded operator in
# the state install-operator.sh would have left it, not from the suite's fixture. On the
# first full 1.20.9 upgrade run (…-upgrade-ocp422-bj487) the cluster-scoped RolloutManager
# in upgrade-rollouts was still there, and with it every Rollouts spec that needs its own
# RolloutManager failed on both legs: 1-100, 1-101 and 1-121, passing on a clean install.
#
# Kept: the operator itself, at the upgraded version, and the suite's patch to the
# default instance in openshift-gitops, which the suites reset where they depend on it.
#
# Order matters. The ApplicationSet and Applications go before the namespaces they deploy
# to, or automated sync recreates those namespaces; the RolloutManager and ArgoCD go
# before their namespaces so the operator, not namespace deletion, tears them down.
echo "--- removing the upgrade suite's fixture ---"
oc delete applicationset,application --all -n upgrade-argocd --ignore-not-found --wait=true --timeout=5m || true
oc delete rollout,rolloutmanager --all -n upgrade-rollouts --ignore-not-found --wait=true --timeout=5m || true
oc delete argocd --all -n upgrade-argocd --ignore-not-found --wait=true --timeout=5m || true
oc delete namespace upgrade-app upgrade-appset upgrade-argocd upgrade-rollouts \
  --ignore-not-found --wait=true --timeout=10m || true

# install-operator.sh sets no config at all. The suite set ARGOCD_CLUSTER_CONFIG_NAMESPACES
# and CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES; without them removed, the default instance
# keeps cluster-wide permissions and Rollouts stays cluster-scoped for upgrade-rollouts.
if oc get subscription "$SUBSCRIPTION_NAME" -n openshift-gitops-operator \
     -o jsonpath='{.spec.config}' 2>/dev/null | grep -q .; then
  oc patch subscription "$SUBSCRIPTION_NAME" -n openshift-gitops-operator --type json \
    -p '[{"op":"remove","path":"/spec/config"}]' || true
  # OLM rewrites the operator Deployment from the Subscription; wait for the env to go
  # and the new pod to be the one running.
  for _ in {1..60}; do
    oc get deployment openshift-gitops-operator-controller-manager -n openshift-gitops-operator \
      -o jsonpath='{.spec.template.spec.containers[*].env}' 2>/dev/null \
      | grep -qE 'ARGOCD_CLUSTER_CONFIG_NAMESPACES|CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES' || break
    sleep 5
  done
  oc rollout status deployment/openshift-gitops-operator-controller-manager \
    -n openshift-gitops-operator --timeout=5m || true
fi

# What the next suites will run against, for whoever reads the log.
echo "--- installed after the upgrade baseline ---"
oc get subscription,csv -n openshift-gitops-operator || true
oc get argocd -A || true

# Without an operator nothing after this can mean anything; tell the leg to stop rather
# than run hours of suites that fail on a missing install.
if ! oc get csv -n openshift-gitops-operator \
     -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -qx Succeeded; then
  echo "::error::no operator installed after the upgrade baseline; skipping the rest of the leg"
  echo "upgrade-baseline left no operator" >> "${SHARED_DIR:-/shared}/stop-suites"
fi
exit $rc
