#!/bin/bash
set -e

# Environment variables expected:
# - UPGRADE (true/false)
# - UPGRADE_TO_CHANNEL (target channel)
# - NAMESPACE (default: openshift-gitops-operator)
# - INSTALL_TIMEOUT (e.g., "25m")
# - KUBECONFIG

# shellcheck source=./lib/wait-for-resources.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/wait-for-resources.sh"

if [[ "$UPGRADE" != "true" ]]; then
  echo "UPGRADE is not enabled, skipping upgrade step"
  exit 0
fi

if [[ -z "$UPGRADE_TO_CHANNEL" ]]; then
  echo "ERROR: UPGRADE is enabled but UPGRADE_TO_CHANNEL is not set"
  exit 1
fi

SUBSCRIPTION_NAME=$(oc get subscription -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
if [[ -z "$SUBSCRIPTION_NAME" ]]; then
  echo "ERROR: No subscription found in namespace ${NAMESPACE}"
  exit 1
fi

CURRENT_CHANNEL=$(oc get subscription "$SUBSCRIPTION_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.channel}')
PRE_UPGRADE_CSV=$(oc get subscription "$SUBSCRIPTION_NAME" -n "$NAMESPACE" -o jsonpath='{.status.installedCSV}')
echo "Current channel: ${CURRENT_CHANNEL}, installed CSV: ${PRE_UPGRADE_CSV}"
echo "Upgrading to channel: ${UPGRADE_TO_CHANNEL}"

oc patch subscription "$SUBSCRIPTION_NAME" -n "$NAMESPACE" --type merge \
  -p "{\"spec\":{\"channel\":\"${UPGRADE_TO_CHANNEL}\",\"installPlanApproval\":\"Automatic\"}}"

echo "Waiting for upgrade to complete..."
if [[ "$INSTALL_TIMEOUT" =~ ^([0-9]+)m$ ]]; then
  TIMEOUT_SECONDS=$(( BASH_REMATCH[1] * 60 ))
elif [[ "$INSTALL_TIMEOUT" =~ ^([0-9]+)s$ ]]; then
  TIMEOUT_SECONDS=${BASH_REMATCH[1]}
else
  TIMEOUT_SECONDS=1500
fi
DEADLINE=$(($(date +%s) + TIMEOUT_SECONDS))

while true; do
  CSV=$(oc get subscription "$SUBSCRIPTION_NAME" -n "$NAMESPACE" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  if [[ -n "$CSV" && "$CSV" != "$PRE_UPGRADE_CSV" ]]; then
    PHASE=$(oc get csv "$CSV" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "CSV: $CSV, Phase: $PHASE"
    if [[ "$PHASE" == "Succeeded" ]]; then
      echo "Upgrade completed successfully: ${PRE_UPGRADE_CSV} -> ${CSV}"

      GITOPS_NS="${GITOPS_NS:-openshift-gitops}"
      echo "Waiting for ArgoCD workloads to reconcile after upgrade..."
      wait_for_argocd_reconciliation "$NAMESPACE" "$GITOPS_NS" 300
      break
    fi
  else
    echo "Waiting for new CSV (current: ${CSV:-none}, pre-upgrade: ${PRE_UPGRADE_CSV})"
  fi

  if [[ $(date +%s) -ge $DEADLINE ]]; then
    echo "ERROR: Upgrade timed out after ${INSTALL_TIMEOUT}"
    oc get subscription "$SUBSCRIPTION_NAME" -n "$NAMESPACE" -o yaml
    oc get csv -n "$NAMESPACE"
    exit 1
  fi

  sleep 30
done
