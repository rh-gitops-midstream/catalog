#!/bin/bash
# goreman stand-in for running the upstream Argo CD e2e suite against a cluster install.
# Source this file and call install_goreman_shim before running e2e.test.
#
# Since v3.x the fixture's EnsureCleanState runs `goreman run status` before every test,
# remote mode included, and fails the test when the binary is missing. Upstream's remote
# harness (test/remote) gets away with it because its runner image carries goreman and a
# Procfile with none of the Argo CD process names in it, so there is nothing to start.
#
# Here the components are Kubernetes workloads, so the stand-in reports no local
# processes and turns the fixture's start requests (RestartProcess, used by the sharding
# tests) into rollout restarts. It cannot apply the environment variables the fixture
# writes to /tmp/argocd-e2e-env, so tests that depend on those fail visibly rather than
# pass by accident.
#
# Uses ARGOCD_NAMESPACE and the ARGOCD_*_NAME component variables, resolved when the shim
# is written. Does nothing when a real goreman is already on PATH.

install_goreman_shim() {
  local kubectl_bin="${1:-kubectl}"
  local shim_dir

  if command -v goreman >/dev/null 2>&1; then
    return 0
  fi

  shim_dir=$(mktemp -d)
  cat > "${shim_dir}/goreman" <<SHIM
#!/bin/bash
# goreman run <status|start|stop> [process]
[[ "\${1:-}" == run ]] || exit 0
case "\${2:-}" in
  start)
    case "\${3:-}" in
      controller)   target="statefulset/${ARGOCD_APPLICATION_CONTROLLER_NAME}" ;;
      api-server)   target="deployment/${ARGOCD_SERVER_NAME}" ;;
      repo-server)  target="deployment/${ARGOCD_REPO_SERVER_NAME}" ;;
      redis)        target="deployment/${ARGOCD_REDIS_NAME}" ;;
      *)            exit 0 ;;
    esac
    ${kubectl_bin} rollout restart "\${target}" -n "${ARGOCD_NAMESPACE}" >&2 &&
      ${kubectl_bin} rollout status "\${target}" -n "${ARGOCD_NAMESPACE}" --timeout=5m >&2
    ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "${shim_dir}/goreman"
  export PATH="${shim_dir}:${PATH}"
  echo "goreman not installed — using the Kubernetes stand-in at ${shim_dir}/goreman"
}
