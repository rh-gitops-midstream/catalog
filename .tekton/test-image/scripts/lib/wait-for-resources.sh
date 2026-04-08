#!/bin/bash
# Utilities for waiting on Kubernetes/OpenShift resources.
# Source this file to use these functions in operator installation/upgrade scripts.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/wait-for-resources.sh"
#   wait_for_deployment openshift-gitops-server openshift-gitops 600s
#   wait_for_operator_pods openshift-gitops-operator

# Wait for a deployment to become available.
# Uses 'oc wait' with condition=Available.
#
# Args:
#   $1 - deployment_name: Name of the deployment
#   $2 - namespace: Namespace containing the deployment
#   $3 - timeout: Timeout duration (default: 600s)
#
# Returns:
#   0 on success, 1 on timeout or failure
#
# Prints:
#   Debug information on failure (pod status, events, IDMS)
#
# Example:
#   wait_for_deployment openshift-gitops-server openshift-gitops 10m
wait_for_deployment() {
    local deployment_name=$1
    local namespace=$2
    local timeout=${3:-600s}

    if ! oc wait --for=condition=Available "deployment/$deployment_name" -n "$namespace" --timeout="$timeout"; then
        echo "ERROR: deployment/$deployment_name did not become Available within $timeout"
        echo "--- Deployment status ---"
        oc get deployment "$deployment_name" -n "$namespace" -o wide 2>/dev/null || true
        echo "--- Pods ---"
        oc get pods -n "$namespace" -o wide 2>/dev/null || true
        echo "--- Pod details ---"
        for pod in $(oc get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
            echo "=== $pod ==="
            oc get pod "$pod" -n "$namespace" -o jsonpath='{range .status.containerStatuses[*]}container={.name} ready={.ready} state={.state}{"\n"}{end}' 2>/dev/null || true
        done
        echo "--- Events ---"
        oc get events -n "$namespace" --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
        echo "--- IDMS ---"
        oc get imagedigestmirrorset 2>/dev/null || echo "No IDMS"
        return 1
    fi

    return 0
}

# Wait for a statefulset to complete rollout.
# Uses 'oc rollout status'.
#
# Args:
#   $1 - statefulset_name: Name of the statefulset
#   $2 - namespace: Namespace containing the statefulset
#   $3 - timeout: Timeout duration (default: 600s)
#
# Returns:
#   0 on success, 1 on timeout or failure
#
# Prints:
#   Debug information on failure
#
# Example:
#   wait_for_statefulset openshift-gitops-application-controller openshift-gitops
wait_for_statefulset() {
    local statefulset_name=$1
    local namespace=$2
    local timeout=${3:-600s}

    if ! oc rollout status "statefulset/$statefulset_name" -n "$namespace" --timeout="$timeout"; then
        echo "ERROR: statefulset/$statefulset_name did not become ready within $timeout"
        oc get pods -n "$namespace" -o wide 2>/dev/null || true
        oc get events -n "$namespace" --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
        return 1
    fi

    return 0
}

# Wait for operator pods to be running and ready.
# Polls until all pods matching a selector are Running with all containers ready.
#
# Args:
#   $1 - namespace: Namespace to check
#   $2 - pod_selector: Substring to match in pod names (default: "openshift-gitops-operator-controller-manager")
#   $3 - max_attempts: Maximum polling attempts (default: 150, ~5 minutes at 2s intervals)
#
# Returns:
#   0 on success, 1 on timeout
#
# Example:
#   wait_for_operator_pods openshift-gitops-operator
#   wait_for_operator_pods my-namespace my-operator 60
wait_for_operator_pods() {
    local namespace=$1
    local pod_selector=${2:-"openshift-gitops-operator-controller-manager"}
    local max_attempts=${3:-150}

    echo "Waiting for operator pods in namespace $namespace to be ready (selector: $pod_selector)"

    for attempt in $(seq 1 "$max_attempts"); do
        local pods
        pods=$(oc get pods --no-headers -n "$namespace" 2>/dev/null | grep "$pod_selector" || true)

        if [ -z "$pods" ]; then
            sleep 2
            continue
        fi

        # Check if all pods are Running (ignore Completed)
        local not_running
        not_running=$(echo "$pods" | grep -v Running | grep -vc Completed || true)
        if [ "$not_running" -ne 0 ]; then
            sleep 2
            continue
        fi

        # Check readiness: all containers in each pod must be ready
        local all_ready=true
        while IFS= read -r pod; do
            local current
            current=$(echo "$pod" | awk '{split($2,a,"/"); print a[1]}')
            local total
            total=$(echo "$pod" | awk '{split($2,a,"/"); print a[2]}')
            if [ "$current" != "$total" ] || [ "$current" -lt 1 ]; then
                all_ready=false
                break
            fi
        done <<< "$pods"

        if $all_ready; then
            echo "All pods are ready (attempt $attempt/$max_attempts)"
            return 0
        fi

        sleep 2
    done

    echo "ERROR: timeout waiting for pods to become ready after $max_attempts attempts"
    oc get pods -n "$namespace" 2>/dev/null || true
    return 1
}

# Wait for a ClusterServiceVersion to reach Succeeded phase.
# Polls subscription status to get CSV name, then waits for CSV to succeed.
#
# Args:
#   $1 - subscription_name: Name of the subscription
#   $2 - namespace: Namespace containing the subscription
#   $3 - timeout: Timeout duration for CSV wait (default: 25m)
#   $4 - max_poll_attempts: Max attempts to find CSV name (default: 30)
#
# Returns:
#   0 on success, 1 on failure
#
# Sets:
#   CSV_NAME variable with the installed CSV name
#
# Example:
#   wait_for_csv gitops-operator-konflux openshift-gitops-operator
#   echo "Installed CSV: $CSV_NAME"
wait_for_csv() {
    local subscription_name=$1
    local namespace=$2
    local timeout=${3:-25m}
    local max_poll_attempts=${4:-30}

    echo "Waiting for ClusterServiceVersion from subscription $subscription_name..."
    sleep 30

    CSV_NAME=""
    for attempt in $(seq 1 "$max_poll_attempts"); do
        CSV_NAME=$(oc get sub "$subscription_name" -n "$namespace" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
        if [ -n "$CSV_NAME" ]; then
            echo "Found CSV: $CSV_NAME (attempt $attempt)"
            break
        fi
        echo "Waiting for subscription status to be updated (attempt $attempt/$max_poll_attempts)..."
        sleep 10
    done

    if [ -z "$CSV_NAME" ]; then
        echo "ERROR: CSV name not found in subscription after $max_poll_attempts attempts"
        oc get sub "$subscription_name" -n "$namespace" -o yaml 2>/dev/null || true
        return 1
    fi

    if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n "$namespace" --timeout="$timeout"; then
        echo "ERROR: CSV $CSV_NAME did not reach Succeeded phase within $timeout"
        oc get csv "$CSV_NAME" -n "$namespace" -o yaml 2>/dev/null || true
        return 1
    fi

    echo "CSV $CSV_NAME is in Succeeded phase"
    return 0
}
