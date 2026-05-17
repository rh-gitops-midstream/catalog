#!/bin/bash
# Script to help reproduce this task execution
#
# Pipeline: gitops-catalog-operator-e2e-bfcxv
# Task: install-operator
# Captured: 2026-05-15 06:18:57 UTC
#
# To use this script:
#   1. Extract the logs artifact: oras pull <quay-ref>
#      tar xzf <task>-logs.tar.gz
#   2. Source the environment: source env.sh
#   3. Set KUBECONFIG: export KUBECONFIG=kubeconfig (if present)
#   4. Run the command below (adjust paths as needed)

set -x

# Original command:
/usr/local/bin/install-operator.sh
