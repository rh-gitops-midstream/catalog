#!/usr/bin/env bash
set -euo pipefail

# Run the Argo CD e2e suite against a cluster you already have.
#
# With no arguments this runs the whole suite once and writes the pipeline's results file
# -- that is how hive-suite-leg invokes it. The subcommands are for working on a failure
# by hand against the same harness CI uses, which is the point of keeping one script:
#
#   run-argocd-e2e-standalone.sh                   # CI: setup, full suite, results JSON
#   run-argocd-e2e-standalone.sh setup             # once, ~15 min (the compile)
#   run-argocd-e2e-standalone.sh run TestNamespacedOrphanedResource
#   run-argocd-e2e-standalone.sh run 'TestCMP|TestCustomTool'
#   run-argocd-e2e-standalone.sh list CMP          # which test names match
#   run-argocd-e2e-standalone.sh logs              # re-attach to a detached run
#   run-argocd-e2e-standalone.sh stop              # kill a run (Ctrl-C only detaches)
#   run-argocd-e2e-standalone.sh shell
#   run-argocd-e2e-standalone.sh teardown [--all]
#
# Provenance: vendored from argocd-e2e-dev.sh, which lived in no repo and was carried in a
# secret gist. Kept as close to that as possible so fixes can move either way; the CI mode,
# the results file and the version-collision guard below are the only additions.
#
# Why this and not run-argocd-e2e-tests.sh: one panic in the fixture takes the whole test
# binary down, and a single nil deref in the hydrator tests truncated a full run at 395 of
# 503. This wraps upstream's own ARGOCD_E2E_RECORD resume hook, names the crashing test from
# the panic stack and continues past it. The older script has no equivalent and silently
# reports a short run as a complete one.
#
# Flags: --namespace NS --argocd-image IMG --argocd-version vX.Y.Z --no-deploy
#        --pull-secret FILE --recompile --timeout 60m --gpg --openshift-tests
#
# The suite runs in a pod on the cluster because it has to: the fixture pushes fixtures to,
# and points Argo CD at, in-cluster service names, so from a laptop every test fails in
# setup on the first git push. It tests a standalone Argo CD, not the operator's, because
# the fixture rewrites argocd-cm and argocd-rbac-cm per test and the operator reverts them.
#
# Unlike CI: nothing is torn down, so the compiled binary survives and re-runs take seconds;
# the run is detached and polled, so Ctrl-C detaches instead of killing it.
#
# Needs KUBECONFIG pointing at the cluster, cluster-admin, and oc (used as a plain kubectl
# everywhere except the SCC grants).
#
# Runs on OpenShift, EKS and GKE. The image under test and its version are read from the
# GitOps operator's Deployment, which the OLM bundle and the xKS Helm chart both name
# openshift-gitops-operator-controller-manager with ARGOCD_IMAGE set. Off OpenShift there is no
# cluster-wide pull secret for registry.redhat.io: pass --pull-secret FILE (a
# .dockerconfigjson), or the xKS chart's own redhat-registry-pull-secret is reused. The tests
# upstream skips as OpenShift-incompatible run by default off OpenShift; --openshift-tests
# forces them on, ARGOCD_E2E_SKIP_OPENSHIFT=true forces them off.

NS="${ARGOCD_E2E_NAMESPACE:-argocd-e2e}"
OPERATOR_NS="${OPERATOR_NAMESPACE:-openshift-gitops-operator}"
GITOPS_NS="${GITOPS_NAMESPACE:-openshift-gitops}"
POD=e2e-test-runner
W=/opt/e2e-test
LOG=$W/run.log
EXITF=$W/run.exit
SHARED_DIR="${SHARED_DIR:-/shared}"

# hive-suite-leg exports TEST_REPO_URL and BRANCH for the gitops-operator suites, where they
# mean that repo and its branch. Here BRANCH means the argo-cd tag to compile the suite from,
# so inheriting the leg's value would clone argo-cd at a gitops-operator branch name and fail
# the checkout. Drop both: this script derives the version from the image under test, which
# cannot drift from the operator the way a hand-set branch can.
unset BRANCH TEST_REPO_URL

IMAGE="" VERSION="" FILTER="" PULL_SECRET_FILE=""
NO_DEPLOY=false RECOMPILE=false ALL=false
SKIP_GPG="${ARGOCD_E2E_SKIP_GPG:-true}"
# auto: skip on OpenShift, where upstream marks them broken, run them everywhere else.
SKIP_OPENSHIFT="${ARGOCD_E2E_SKIP_OPENSHIFT:-auto}"
PULL_SECRET=argocd-e2e-pull-secret PULL_SECRET_READY=false
TIMEOUT="${ARGOCD_E2E_TEST_TIMEOUT:-60m}"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo; echo "=== $*"; }

# The SCC API is the thing that actually differs -- grants against it fail outright elsewhere.
# Captured rather than piped into grep -q: under pipefail an early grep exit SIGPIPEs oc and
# the pipeline reads as false on OpenShift. Cached; call it directly, not in $( ).
is_openshift() {
  if [[ -z "${_IS_OPENSHIFT:-}" ]]; then
    local r
    r=$(oc api-resources --api-group=security.openshift.io -o name 2>/dev/null || true)
    if [[ "$r" == *securitycontextconstraints* ]]; then _IS_OPENSHIFT=true; else _IS_OPENSHIFT=false; fi
  fi
  [[ "$_IS_OPENSHIFT" == true ]]
}

# No argument means CI: the pipeline calls this as a bare suite script. Interactive use
# always names a subcommand, so the usage text is no longer the empty-argument case.
CMD="${1:-ci}"
[[ $# -eq 0 ]] || shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)       NS="$2"; shift 2 ;;
    --argocd-image)    IMAGE="$2"; shift 2 ;;
    --argocd-version)  VERSION="$2"; shift 2 ;;
    --pull-secret)     PULL_SECRET_FILE="$2"; shift 2 ;;
    --timeout)         TIMEOUT="$2"; shift 2 ;;
    --no-deploy)       NO_DEPLOY=true; shift ;;
    --recompile)       RECOMPILE=true; shift ;;
    --gpg)             SKIP_GPG=false; shift ;;
    --openshift-tests) SKIP_OPENSHIFT=false; shift ;;
    --all)             ALL=true; shift ;;
    -*)                die "unknown option $1" ;;
    *)                 FILTER="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------- setup ---

cmd_setup() {
  # can-i rather than whoami: whoami asks OpenShift's user API, which EKS and GKE lack.
  oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 \
    || die "not logged in as cluster-admin -- check KUBECONFIG"
  if is_openshift; then echo "Platform: OpenShift"; else echo "Platform: Kubernetes (no SCC API)"; fi

  if [[ "$NO_DEPLOY" == false && -z "$IMAGE" ]]; then
    IMAGE=$(operator_argocd_image)
    [[ -n "$IMAGE" ]] || die "no ARGOCD_IMAGE on the GitOps operator in ${OPERATOR_NS}; pass --argocd-image"
  fi
  # Before the version probe below, which has to pull the image under test.
  [[ "$NO_DEPLOY" == true ]] || ensure_pull_secret

  # The version picks the argo-cd tag the suite is compiled from, so it has to match the
  # server under test or you debug a different suite than you deployed.
  if [[ -z "$VERSION" ]]; then
    if [[ "$NO_DEPLOY" == true ]]; then
      VERSION=$(server_version "$NS" argocd-server)
    else
      # The image under test first: the default instance can run a different image -- an
      # older operator's, or not the one --argocd-image names -- and the xKS chart does not
      # create a default instance at all.
      VERSION=$(image_version)
      [[ -n "$VERSION" ]] || VERSION=$(server_version "$GITOPS_NS" openshift-gitops-server)
    fi
    [[ -n "$VERSION" ]] || die "could not read the Argo CD version; pass --argocd-version"
    echo "Argo CD ${VERSION}"
  fi

  if [[ "$NO_DEPLOY" == false ]]; then
    deploy_argocd
  else
    echo "--no-deploy: using the Argo CD already in ${NS}"
  fi

  deploy_e2e_server
  deploy_runner
  say "Compiling the suite -- 10-15 minutes, once per pod"
  run_in_pod '^$'
  say "Ready.  $0 run TestFoo"
  if is_openshift; then
    oc get route argocd-server -n "$NS" -o jsonpath='UI: https://{.spec.host}  admin/password{"\n"}' 2>/dev/null || true
  else
    echo "UI: oc port-forward svc/argocd-server -n ${NS} 8080:443, then https://localhost:8080  admin/password"
  fi
}

# The operator Deployment carries the image it deploys as ARGOCD_IMAGE, under the same name in
# the OLM bundle and the xKS chart -- and on xKS it reflects any registry retargeting the
# chart's install applied, which the chart's values do not. The CSV is a fallback for an OLM
# install that names its Deployment differently.
operator_argocd_image() {
  local img
  img=$(oc get deploy openshift-gitops-operator-controller-manager -n "$OPERATOR_NS" \
          -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="ARGOCD_IMAGE")].value}' \
          2>/dev/null || true)
  if [[ -z "$img" ]] && command -v jq >/dev/null; then
    local csv
    csv=$(oc get csv -n "$OPERATOR_NS" -o name 2>/dev/null | sed 's|.*/||' | grep -i gitops | head -1 || true)
    [[ -z "$csv" ]] || img=$(oc get csv "$csv" -n "$OPERATOR_NS" -o json | jq -r \
      '[.spec.relatedImages[]?.image] | map(select(test("argocd-rhel|argo-cd"))) | first // empty')
  fi
  [[ -z "$img" ]] || echo "Image ${img} (from the operator in ${OPERATOR_NS})" >&2
  echo "${img%% *}"
}

server_version() {
  oc exec -n "$1" "deploy/$2" -- argocd-server version --short 2>/dev/null \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

# Asks the image under test itself, so no running Argo CD is needed. A pod rather than
# `oc run --rm -i`: attach races a container that exits in under a second and can drop the
# output. Hardened like install.yaml's own containers, which this image already runs under,
# so a namespace enforcing the restricted Pod Security profile admits it. On an image pull
# failure it says why instead of just timing out.
image_version() {
  local p=argocd-version-probe v="" reason ips=""
  [[ "$PULL_SECRET_READY" == false ]] || ips="imagePullSecrets: [{name: ${PULL_SECRET}}]"
  oc delete pod "$p" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: ${p}, namespace: ${NS}}
spec:
  restartPolicy: Never
  ${ips}
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: probe
    image: ${IMAGE}
    command: [argocd, version, --client, --short]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
EOF
  if oc wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${p}" -n "$NS" --timeout=3m >/dev/null 2>&1; then
    v=$(oc logs "pod/${p}" -n "$NS" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  else
    reason=$(oc get pod "$p" -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
    echo "version probe did not run${reason:+ (${reason})}${reason:+ -- is --pull-secret needed?}" >&2
  fi
  oc delete pod "$p" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "$v"
}

# Does the image under test actually ship the commit-server binary?
#
# It is not a given. The commit-server backs the source hydrator, which arrived in Argo CD
# 3.5 -- GitOps 1.22 and later. On a 1.21.x image (Argo CD 3.4.x) the binary is absent and
# the Deployment below dies in CreateContainerError with "executable file
# /usr/local/bin/argocd-commit-server not found", which fails the whole setup even though
# every other component is healthy. Seen on GitOps 1.21.5 / Argo CD 3.4.10, 2026-10-06.
#
# Asked of the image rather than inferred from the version string, because --argocd-version
# can be overridden to an upstream tag that does not match the image -- which is exactly
# what a z-stream shipping an untagged patch forces you to do.
image_has_commit_server() {
  local p=argocd-commitsrv-probe ips=""
  [[ "$PULL_SECRET_READY" == false ]] || ips="imagePullSecrets: [{name: ${PULL_SECRET}}]"
  oc delete pod "$p" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: ${p}, namespace: ${NS}}
spec:
  restartPolicy: Never
  ${ips}
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: probe
    image: ${IMAGE}
    command: [sh, -c, "test -x /usr/local/bin/argocd-commit-server"]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
EOF
  local rc=1
  if oc wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${p}" -n "$NS" --timeout=3m >/dev/null 2>&1; then
    rc=0
  fi
  oc delete pod "$p" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  return $rc
}

# OpenShift's cluster-wide pull secret already covers registry.redhat.io, so there this only
# acts on an explicit --pull-secret. Elsewhere it falls back to the xKS chart's secret. That is
# copied as the base64 it is stored as -- never decoded, never written locally.
ensure_pull_secret() {
  oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
  if [[ -n "$PULL_SECRET_FILE" ]]; then
    [[ -r "$PULL_SECRET_FILE" ]] || die "--pull-secret ${PULL_SECRET_FILE}: not readable"
    oc create secret generic "$PULL_SECRET" -n "$NS" --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="$PULL_SECRET_FILE" --dry-run=client -o yaml | oc apply -f - >/dev/null
    echo "Pull secret: ${PULL_SECRET} from ${PULL_SECRET_FILE}"
  elif is_openshift; then
    return 0
  else
    local src data=""
    src=redhat-registry-pull-secret
    oc get secret "$src" -n "$OPERATOR_NS" >/dev/null 2>&1 \
      || src=$(oc get secret -n "$OPERATOR_NS" -l operator.argoproj.io/propagate-image-pull-secret=true \
                 --field-selector type=kubernetes.io/dockerconfigjson -o name 2>/dev/null \
                 | head -1 | sed 's|.*/||' || true)
    [[ -z "$src" ]] || data=$(oc get secret "$src" -n "$OPERATOR_NS" \
                                -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null || true)
    if [[ -z "$data" ]]; then
      echo "WARNING: no --pull-secret and no usable pull secret in ${OPERATOR_NS} --" \
           "registry.redhat.io images will not pull"
      return 0
    fi
    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata: {name: ${PULL_SECRET}, namespace: ${NS}}
type: kubernetes.io/dockerconfigjson
data: {".dockerconfigjson": "${data}"}
EOF
    echo "Pull secret: ${PULL_SECRET} (copied from ${OPERATOR_NS}/${src})"
  fi
  PULL_SECRET_READY=true
}

# Appended, never replaced: on OpenShift every ServiceAccount already lists its own dockercfg
# secret, and a merge patch of imagePullSecrets would drop it.
link_pull_secret() {
  [[ "$PULL_SECRET_READY" == true ]] || return 0
  local sa cur i
  # `default` is made asynchronously after the namespace; everything else came from the apply.
  for i in $(seq 1 30); do oc get sa default -n "$NS" >/dev/null 2>&1 && break; sleep 1; done
  for sa in $(oc get sa -n "$NS" -o name); do
    cur=$(oc get "$sa" -n "$NS" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || true)
    case " $cur " in *" ${PULL_SECRET} "*) continue ;; esac
    if [[ -z "$cur" ]]; then
      oc patch "$sa" -n "$NS" --type merge -p "{\"imagePullSecrets\":[{\"name\":\"${PULL_SECRET}\"}]}" >/dev/null
    else
      oc patch "$sa" -n "$NS" --type json \
        -p "[{\"op\":\"add\",\"path\":\"/imagePullSecrets/-\",\"value\":{\"name\":\"${PULL_SECRET}\"}}]" >/dev/null
    fi
  done
}

deploy_argocd() {
  say "Deploying standalone Argo CD ${VERSION} into ${NS}"
  for n in "$NS" argocd-e2e-external argocd-e2e-external-2; do
    oc create namespace "$n" --dry-run=client -o yaml | oc apply -f - >/dev/null
  done

  # Upstream's install.yaml is already non-root/seccomp-hardened, but dex pins UID 1001 and
  # redis 999, outside the namespace range restricted-v2 allows. anyuid admits the UID and
  # then rejects RuntimeDefault seccomp; nonroot-v2 admits the profile as written, so no
  # manifest needs patching. Granted before the apply so the first pods are admitted.
  # Off OpenShift there is no SCC to grant: EKS and GKE do not apply the restricted Pod
  # Security level to an unlabelled namespace, so these UIDs are admitted as they are.
  if is_openshift; then
    oc adm policy add-scc-to-group nonroot-v2 "system:serviceaccounts:${NS}" >/dev/null
    oc -n "$NS" adm policy add-scc-to-user privileged -z default >/dev/null 2>&1 || true
  fi
  # One named binding in plain RBAC, which every cluster has, instead of `oc adm policy`;
  # teardown --all removes it by name. `default` is the runner's identity.
  oc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: argocd-e2e-${NS}-cluster-admin}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin}
subjects:
- {kind: ServiceAccount, name: default, namespace: ${NS}}
- {kind: ServiceAccount, name: argocd-application-controller, namespace: ${NS}}
- {kind: ServiceAccount, name: argocd-applicationset-controller, namespace: ${NS}}
- {kind: ServiceAccount, name: argocd-server, namespace: ${NS}}
EOF

  # --server-side: the applicationsets CRD blows the 256KB last-applied annotation on v3.x.
  curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/${VERSION}/manifests/install.yaml" \
    | sed "s/namespace: argocd$/namespace: ${NS}/" \
    | oc apply --server-side --force-conflicts -n "$NS" -f - >/dev/null
  # Before `oc set image` below: a pod picks up its ServiceAccount's pull secrets at creation.
  link_pull_secret

  # Redis refuses to start with an empty --requirepass.
  oc create secret generic argocd-redis --from-literal=auth=argocd-e2e-redis-password \
    -n "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null

  # The fixture logs in as admin/password against this hash. Upstream's test manifests patch
  # it in; install.yaml does not.
  oc patch secret argocd-secret -n "$NS" --type merge -p '{"stringData":{
    "admin.password":"$2a$10$RncPyHW/B5ll2Z3J8s.IBOnbZ9uoJ4JhHLKzj5lzG/kU1KN1Oj3/K",
    "admin.passwordMtime":"2019-03-20T17:54:53Z"}}' >/dev/null

  # enable.scm.providers=false is deliberate. Upstream points the applicationset controller at
  # ARGOCD_APPLICATIONSET_CONTROLLER_ALLOWED_SCM_PROVIDERS=http://127.0.0.1:8341..8344, mock
  # servers the *test process* opens on its own loopback. A controller in a pod cannot reach
  # those, so the SCM/PR generator tests cannot pass in remote mode however this is set;
  # false at least lets the "provider not allowed" tests pass.
  # Everything upstream's `make start-e2e-local` exports that stock install.yaml wires to a
  # cmd-params key. ARGOCD_ZJWT_FEATURE_FLAG and ARGOCD_E2E_DISABLE_AUTH are also in that
  # Makefile block but have no references left in v3.5.2 and no key here, so they are dropped.
  oc patch configmap argocd-cmd-params-cm -n "$NS" --type merge -p '{"data":{
    "application.namespaces":"argocd-e2e-external,argocd-e2e-external-2",
    "applicationsetcontroller.namespaces":"argocd-e2e-external,argocd-e2e-external-2",
    "applicationsetcontroller.enable.tokenref.strict.mode":"true",
    "applicationsetcontroller.enable.scm.providers":"false",
    "hydrator.enabled":"true",
    "controller.cluster.cache.events.processing.interval":"'"${CACHE_EVENT_INTERVAL:-1ms}"'"}}' >/dev/null

  # Every component that runs the argocd binary, not just the API server. Manifest rendering
  # -- the thing the bundled helm and kustomize actually do -- happens in the repo-server, so
  # leaving it on upstream's image tests upstream's tools. dex and redis have their own images.
  for w in server repo-server applicationset-controller notifications-controller; do
    oc set image "deployment/argocd-${w}" "argocd-${w}=${IMAGE}" -n "$NS" >/dev/null
  done
  oc set image statefulset/argocd-application-controller \
    "argocd-application-controller=${IMAGE}" -n "$NS" >/dev/null

  # The source hydrator pushes through a commit-server, which stock install.yaml does not
  # ship -- upstream only runs it from the Procfile. Without it all 13 hydrator tests fail,
  # and HydrationPhaseIs nil-derefs Status.SourceHydrator.CurrentOperation, panicking the
  # whole binary. The controller defaults to argocd-commit-server:8086, so the name is the
  # only wiring needed.
  #
  # Only when the image has the binary. The hydrator is a 3.5 feature, so a 1.21.x image
  # does not carry it, and deploying this anyway fails setup outright in
  # CreateContainerError while every other component is healthy. Skipping it instead means
  # the hydrator tests fail on a 3.4 image -- which is the honest outcome, since there is
  # no hydrator there to test.
  if ! image_has_commit_server; then
    echo "Image has no argocd-commit-server (pre-3.5): skipping it; hydrator tests will fail"
    # Remove one a previous run on a 3.5+ image may have left behind. Without this the
    # rollout loop below -- which enumerates every deploy in the namespace rather than a
    # fixed list -- waits 10 minutes on a Deployment that can never start, and setup dies
    # there instead of running.
    oc delete deployment,service argocd-commit-server -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
    COMMIT_SERVER_DEPLOYED=false
  else
  oc apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: argocd-commit-server, namespace: ${NS}}
spec:
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: argocd-commit-server}}
  template:
    metadata: {labels: {app.kubernetes.io/name: argocd-commit-server}}
    spec:
      containers:
      - name: argocd-commit-server
        image: ${IMAGE}
        command: [/usr/local/bin/argocd-commit-server, --loglevel, debug, --port, "8086"]
        ports: [{containerPort: 8086}, {containerPort: 8087}]
        securityContext:
          runAsNonRoot: true
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: {drop: [ALL]}
          seccompProfile: {type: RuntimeDefault}
        volumeMounts: [{name: tmp, mountPath: /tmp}]
      volumes: [{name: tmp, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata: {name: argocd-commit-server, namespace: ${NS}}
spec:
  selector: {app.kubernetes.io/name: argocd-commit-server}
  ports: [{name: server, port: 8086, targetPort: 8086}, {name: metrics, port: 8087, targetPort: 8087}]
EOF
    COMMIT_SERVER_DEPLOYED=true
  fi

  if is_openshift; then
    oc create route passthrough argocd-server --service=argocd-server --port=https -n "$NS" \
      >/dev/null 2>&1 || true
  fi

  # Patch first, restart once, wait once -- the controllers read cmd-params through env
  # valueFrom, so pods created by the apply above have the wrong namespace list. Every
  # workload is waited on, not a subset: an SCC rejection should fail here, not later as a
  # mystery test failure.
  local workloads w
  workloads=$(oc get deploy,statefulset -n "$NS" -o name)
  # shellcheck disable=SC2086
  oc rollout restart $workloads -n "$NS" >/dev/null
  for w in $workloads; do
    oc rollout status "$w" -n "$NS" --timeout=10m \
      || { oc get pods -n "$NS" -o wide; die "$w never became ready"; }
  done
}

deploy_e2e_server() {
  say "Deploying the e2e git/helm server"
  # Upstream's test fixture image: git over http/https/client-cert/ssh plus a helm repo,
  # all driven by its own goreman Procfile. SYS_CHROOT is for sshd.
  oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: argocd-e2e-cluster, namespace: ${NS}}
spec:
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: argocd-e2e-server}}
  template:
    metadata: {labels: {app.kubernetes.io/name: argocd-e2e-server}}
    spec:
      containers:
      - name: argocd-e2e-server
        image: ${E2E_SERVER_IMAGE:-quay.io/redhat-developer/argocd-e2e-cluster:latest}
        command: [goreman, start]
        securityContext: {capabilities: {add: [SYS_CHROOT]}}
        resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {memory: 512Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: argocd-e2e-server, namespace: ${NS}}
spec:
  selector: {app.kubernetes.io/name: argocd-e2e-server}
  ports:
  - {name: helm, port: 9080}
  - {name: git-http, port: 9081}
  - {name: git-https, port: 9443}
  - {name: git-ccert, port: 9444}
  - {name: git-ssh, port: 2222}
EOF
  oc rollout status deployment/argocd-e2e-cluster -n "$NS" --timeout=5m
}

deploy_runner() {
  say "Deploying the runner pod"
  # emptyDir, restartPolicy Never: the compiled binary lives and dies with this pod.
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: ${POD}, namespace: ${NS}}
spec:
  restartPolicy: Never
  containers:
  - name: runner
    image: ${TEST_RUNNER_IMAGE:-registry.access.redhat.com/ubi9/go-toolset:latest}
    command: [sleep, infinity]
    securityContext: {runAsUser: 0}
    resources: {requests: {cpu: 500m, memory: 512Mi}, limits: {memory: 8Gi}}
    volumeMounts:
    - {name: work, mountPath: ${W}}
    - {name: bin, mountPath: /tmp/bin}
  volumes:
  - {name: work, emptyDir: {}}
  - {name: bin, emptyDir: {}}
EOF
  oc wait --for=condition=Ready "pod/${POD}" -n "$NS" --timeout=5m

  say "Installing tools in the runner"
  # go-toolset has none of these. kubectl for the fixture, gpg because EnsureCleanState
  # imports a key before every test. helm and kustomize are installed later, from the
  # checkout, because their versions depend on the Argo CD release.
  # Each step announces itself: under `set -e` a silent non-zero here used to abort the
  # whole exec with nothing to go on.
  oc exec -n "$NS" "$POD" -- bash -c '
    set -euo pipefail
    case "$(uname -m)" in x86_64) A=amd64 ;; aarch64) A=arm64 ;; *) A=$(uname -m) ;; esac
    if ! command -v git >/dev/null || ! command -v gpg >/dev/null; then
      echo "  git, gnupg2"; dnf install -y git gnupg2 >/dev/null
    fi
    if ! command -v kubectl >/dev/null; then
      echo "  kubectl"
      curl -fsSLo /tmp/bin/kubectl \
        "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${A}/kubectl"
    fi
    chmod +x /tmp/bin/* 2>/dev/null || true
    echo "  ok: $(ls /tmp/bin | tr "\\n" " ")"' || die "tool install in ${POD} failed (see above)"

  # Take argocd, helm and kustomize out of the Argo CD image under test rather than
  # installing our own. Whether the helm and kustomize Red Hat bundles behave is a large
  # part of why this suite gets run at all, so upstream's pinned versions are a fallback,
  # not the default. (The repo-server renders with the image's copies regardless; these
  # are the ones the fixture and the local-render tests shell out to.)
  say "Taking argocd, helm and kustomize from the Argo CD image"
  local server b dir src want got attempt
  server=$(oc get pods -n "$NS" -l app.kubernetes.io/name=argocd-server \
             -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$server" ]]; then
    echo "  WARNING: no argocd-server pod -- the runner will fall back to upstream's versions"
    return 0
  fi
  oc exec -n "$NS" "$POD" -- mkdir -p /tmp/rc-argocd
  # The runner fetches these itself, with its own kubectl and cluster-admin, so the bytes never
  # leave the cluster. Through the laptop (`oc exec cat | oc exec -i`) the 334MB argocd took
  # 32-95s and came across corrupt 2 times in 3 on 2026-09-22; in-cluster it took 1-2s, 3 of 3
  # intact -- and EKS/GKE put a longer path between laptop and API server, not a shorter one.
  # (`oc cp` is worse still: it once truncated an 83MB helm to 15MB and exited 0.) The laptop
  # stream stays as the fallback. Every copy is checked against the image's own md5 and lands
  # as .part first, so a failed attempt can never replace a binary that was already intact.
  for b in argocd helm kustomize; do
    src=; want=
    for dir in /usr/local/bin /usr/bin; do
      want=$(oc exec -n "$NS" "$server" -c argocd-server -- md5sum "${dir}/${b}" 2>/dev/null \
               | cut -d' ' -f1) || true
      if [[ -n "$want" ]]; then src="${dir}/${b}"; break; fi
    done
    if [[ -z "$src" ]]; then
      oc exec -n "$NS" "$POD" -- rm -f "/tmp/rc-argocd/${b}"
      echo "  ${b}: not in the image -- upstream's pinned version will be used"
      continue
    fi
    got=$(oc exec -n "$NS" "$POD" -- md5sum "/tmp/rc-argocd/${b}" 2>/dev/null | cut -d' ' -f1) || true
    if [[ "$got" == "$want" ]]; then
      echo "  ${b}: ${src} (already intact)"
      continue
    fi
    for attempt in 1 2 3; do
      oc exec -n "$NS" "$POD" -- bash -c \
        "/tmp/bin/kubectl exec -n '${NS}' '${server}' -c argocd-server -- cat '${src}' > /tmp/rc-argocd/${b}.part" \
        2>/dev/null \
      || oc exec -n "$NS" "$server" -c argocd-server -- cat "$src" \
           | oc exec -i -n "$NS" "$POD" -- bash -c "cat > /tmp/rc-argocd/${b}.part"
      got=$(oc exec -n "$NS" "$POD" -- md5sum "/tmp/rc-argocd/${b}.part" 2>/dev/null | cut -d' ' -f1) || true
      [[ "$got" == "$want" ]] && break
      echo "  ${b}: attempt ${attempt} came across corrupt, retrying"
    done
    if [[ "$got" != "$want" ]]; then
      # Whatever was there did not match this image either, so it goes too.
      oc exec -n "$NS" "$POD" -- rm -f "/tmp/rc-argocd/${b}.part" "/tmp/rc-argocd/${b}"
      echo "  ${b}: could not copy intact -- upstream's pinned version will be used"
      continue
    fi
    oc exec -n "$NS" "$POD" -- bash -c "mv /tmp/rc-argocd/${b}.part /tmp/rc-argocd/${b} && chmod +x /tmp/rc-argocd/${b}"
    echo "  ${b}: ${src}"
  done

  push_runner_script
}

# ------------------------------------------------------------------ in the pod ---
#
# Written into the pod rather than kept as a second file, so this script stays the only
# thing you have to carry. Quoted heredoc: nothing below is expanded here, all of it is
# expanded in the pod.

push_runner_script() {
  oc exec -i -n "$NS" "$POD" -- bash -c "cat > ${W}/run.sh" <<'POD_SCRIPT'
#!/bin/bash
set -uo pipefail
W=/opt/e2e-test; SRC=$W/argo-cd
: "${ARGOCD_NAMESPACE:?must be passed in}"
BRANCH="${BRANCH:-$(cat $W/branch 2>/dev/null)}"
export HOME=$W GOCACHE=$W/go-cache GOMODCACHE=$W/go-mod GOTOOLCHAIN=auto
export GODEBUG="tarinsecurepath=0,zipinsecurepath=0" GIT_TERMINAL_PROMPT=0
export PATH="$SRC/dist:/tmp/bin:$PATH"
git config --global --add safe.directory '*'
git config --global user.email e2e@example.com
git config --global user.name e2e

# --- compile, once per pod -------------------------------------------------------
if [[ ! -f $SRC/e2e.test ]]; then
  [[ -n "$BRANCH" ]] || { echo "ERROR: nothing compiled in this pod and no Argo CD version known -- run setup, or pass --argocd-version"; exit 1; }
  echo "$BRANCH" > $W/branch
  git clone --branch "$BRANCH" --depth 1 https://github.com/argoproj/argo-cd.git "$SRC" || exit 1
  cd "$SRC" || exit 1
  V=$(cat VERSION 2>/dev/null || echo "$BRANCH"); V=${V#v}
  MOD=$(awk 'NR==1{print $2}' go.mod)
  go mod download || exit 1
  echo "Compiling e2e.test (10-15 min)..."
  ( while sleep 60; do echo "  still compiling..."; done ) & HB=$!
  go test -c -ldflags "-X ${MOD}/common.version=${V}" -o e2e.test ./test/e2e; rc=$?
  kill $HB 2>/dev/null
  [[ $rc -eq 0 ]] || { echo "ERROR: compile failed"; exit 1; }
  mkdir -p dist
  if [[ -x /tmp/rc-argocd/argocd ]]; then
    cp /tmp/rc-argocd/argocd dist/argocd
  else
    go build -ldflags "-X ${MOD}/common.version=${V}" -o dist/argocd ./cmd || exit 1
  fi
fi

# --- helm and kustomize -------------------------------------------------------------
# The ones bundled in the Argo CD image win. Upstream's pins in hack/tool-versions.sh only
# fill a gap, and the gap is announced: a run on upstream's helm is answering a different
# question than a run on the bundled one. Those pins also move between releases -- v2.14
# wants helm 3.16, v3.0 3.17, v3.5 helm *4* -- so they are read from the checkout, not
# hardcoded, on the chance the fallback is ever taken.
case "$(uname -m)" in x86_64) A=amd64 ;; aarch64) A=arm64 ;; *) A=$(uname -m) ;; esac
for b in helm kustomize; do
  if [[ -x /tmp/rc-argocd/$b ]]; then cp -f "/tmp/rc-argocd/$b" "/tmp/bin/$b"; fi
done
# shellcheck source=/dev/null
source "$SRC/hack/tool-versions.sh" 2>/dev/null || true
# Gate on the binary actually running, not on `command -v`: a truncated copy out of the
# image is on PATH and segfaults, which reads as a mysterious test failure much later.
if ! timeout 30 helm version >/dev/null 2>&1; then
  HELM_V="${helm4_version:-${helm3_version:-}}"
  echo "WARNING: no working helm from the Argo CD image -- falling back to upstream's pin ${HELM_V}"
  curl -fsSL "https://get.helm.sh/helm-v${HELM_V}-linux-${A}.tar.gz" \
    | tar -xz -C /tmp/bin --strip-components=1 "linux-${A}/helm" || exit 1
fi
if ! timeout 30 kustomize version >/dev/null 2>&1; then
  KUST_V="${kustomize5_version:-${kustomize_version:-}}"
  echo "WARNING: no working kustomize from the Argo CD image -- falling back to upstream's pin ${KUST_V}"
  curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUST_V}/kustomize_v${KUST_V}_linux_${A}.tar.gz" \
    | tar -xz -C /tmp/bin kustomize || exit 1
fi

# --- the fixture's environment ---------------------------------------------------
# ARGOCD_E2E_REMOTE means "Argo CD is not local processes"; everything is reached by
# in-cluster service name, which is why this has to run in the cluster.
export ARGOCD_E2E_REMOTE=true
export ARGOCD_SERVER="argocd-server.${ARGOCD_NAMESPACE}.svc.cluster.local"
export ARGOCD_E2E_ADMIN_USERNAME=admin
export ARGOCD_E2E_ADMIN_PASSWORD=password
export ARGOCD_E2E_NAMESPACE="$ARGOCD_NAMESPACE"
export ARGOCD_E2E_APP_NAMESPACE=argocd-e2e-external
export ARGOCD_APPLICATION_NAMESPACES=argocd-e2e-external,argocd-e2e-external-2
export ARGOCD_E2E_SERVER_NAME=argocd-server
export ARGOCD_E2E_REDIS_NAME=argocd-redis
export ARGOCD_E2E_REPO_SERVER_NAME=argocd-repo-server
export ARGOCD_E2E_APPLICATION_CONTROLLER_NAME=argocd-application-controller
G=http://argocd-e2e-server:9081/argo-e2e
export ARGOCD_E2E_GIT_SERVICE="$G/testdata.git"
export ARGOCD_E2E_REPO_DEFAULT="$G/testdata.git"
export ARGOCD_E2E_GIT_SERVICE_SUBMODULE="$G/submodule.git"
export ARGOCD_E2E_GIT_SERVICE_SUBMODULE_PARENT="$G/submoduleParent.git"
export ARGOCD_E2E_HELM_SERVICE=http://argocd-e2e-server:9081/helm-repo
export ARGOCD_E2E_REPO_SSH=ssh://root@argocd-e2e-server:2222/tmp/argo-e2e/testdata.git
export ARGOCD_E2E_REPO_SSH_SUBMODULE=ssh://root@argocd-e2e-server:2222/tmp/argo-e2e/submodule.git
export ARGOCD_E2E_REPO_SSH_SUBMODULE_PARENT=ssh://root@argocd-e2e-server:2222/tmp/argo-e2e/submoduleParent.git
export ARGOCD_E2E_REPO_HTTPS=https://argocd-e2e-server:9443/argo-e2e/testdata.git
export ARGOCD_E2E_REPO_HTTPS_SUBMODULE=https://argocd-e2e-server:9443/argo-e2e/submodule.git
export ARGOCD_E2E_REPO_HTTPS_SUBMODULE_PARENT=https://argocd-e2e-server:9443/argo-e2e/submoduleParent.git
export ARGOCD_E2E_REPO_HTTPS_CLIENT_CERT=https://argocd-e2e-server:9444/argo-e2e/testdata.git
export ARGOCD_E2E_REPO_HELM=https://argocd-e2e-server:9444/helm-repo
export ARGOCD_E2E_SKIP_HELM=false
export ARGOCD_E2E_K3S=true
export ARGOCD_E2E_DEFAULT_TIMEOUT=30
export ARGOCD_GPG_ENABLED=true
export NO_PROXY='*'
export ARGOCD_E2E_SKIP_GPG="${ARGOCD_E2E_SKIP_GPG:-true}"
export ARGOCD_E2E_SKIP_OPENSHIFT="${ARGOCD_E2E_SKIP_OPENSHIFT:-true}"
export ARGOCD_E2E_SKIP="${ARGOCD_E2E_SKIP:-}"

# Upstream ships exactly four skip switches -- ARGOCD_E2E_SKIP_{GPG,OPENSHIFT,HELM,KSONNET}
# (KSONNET is dead, nothing reads it) -- plus ARGOCD_E2E_K3S, and all of them are set above.
# None of them covers the tests that are impossible in remote mode: only sharding_test.go
# consults IsRemote(), everything else assumes the test process and Argo CD share a host.
# So they have to be excluded by name, with `go test -test.skip`.
#
#   TestCMP* / TestCustomTool* / TestHydratorWithPlugin / TestPreserveFileModeForCMP /
#   TestPruneResourceFromCMP  -- RunningCMPServer() starts a CMP server inside the test
#     process and writes its socket under fixture.TmpDir(); the repo-server has to see that
#     same socket (upstream's Procfile: ARGOCD_PLUGINSOCKFILEPATH=./test/cmp). A repo-server
#     in a pod cannot.
#   TestSimpleSCMProviderGenerator* / TestSimplePullRequestGenerator* -- bind mock providers
#     on the test process's 127.0.0.1:8341..8344. The applicationset controller in a pod
#     dials its own loopback and finds nothing. (TestSCMProviderGeneratorSCMProviderNotAllowed
#     and TestPullRequestGeneratorNotAllowedSCMProvider bind nothing and are not skipped, but
#     they fail too, on OpenShift and on EKS alike -- not yet diagnosed.)
#   TestKubectlMetrics -- GETs http://127.0.0.1:8082/metrics and :8083, the controller's and
#     the API server's metrics ports, which are pod-local here.
#   TestGitGeneratorPrivateRepoWithTemplatedProjectAndProjectScopedRepo -- opens a redis
#     client to localhost:6379 to flush the repo-server cache, and require.NoError's on it.
#
# Skipped rather than left to fail so the summary stays readable; SKIP_LOCAL_ONLY=false runs
# them anyway. Note the pipeline does not skip these, so they are 24 of its failures.
if [[ "${SKIP_LOCAL_ONLY:-true}" == true ]]; then
  LOCAL_ONLY='TestCMP.*|TestCustomTool.*|TestHydratorWithPlugin|TestPreserveFileModeForCMP'
  LOCAL_ONLY="${LOCAL_ONLY}|TestPruneResourceFromCMP|TestSimpleSCMProviderGenerator.*"
  LOCAL_ONLY="${LOCAL_ONLY}|TestSimplePullRequestGenerator.*|TestKubectlMetrics"
  LOCAL_ONLY="${LOCAL_ONLY}|TestGitGeneratorPrivateRepoWithTemplatedProjectAndProjectScopedRepo"
  if [[ -n "$ARGOCD_E2E_SKIP" ]]; then
    export ARGOCD_E2E_SKIP="${ARGOCD_E2E_SKIP}|${LOCAL_ONLY}"
  else
    export ARGOCD_E2E_SKIP="$LOCAL_ONLY"
  fi
  # -test.list ignores -test.skip, so saying this during `list` would only mislead.
  [[ -n "${LIST_ONLY:-}" ]] || cat <<'MSG'
Skipping up to 24 tests that need Argo CD on the test process's own host -- CMP plugins,
SCM/PullRequest generators, controller metrics ports, redis flush. SKIP_LOCAL_ONLY=false
runs them anyway.
MSG
fi

# On FIPS, gpg cannot honour the test key's 3DES preferences, so `gpg --import` prompts,
# finds no /dev/tty and exits 2 -- after importing. EnsureCleanState imports before every
# test, so without --batch the whole suite fails in setup. Harmless off FIPS.
if [[ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" == 1 ]]; then
  # Resolve the real gpg from the system path, NOT through PATH: /tmp/bin comes first and
  # already holds this wrapper on any run after the first, so `command -v gpg` would return
  # the wrapper and we would write one that execs itself forever. The pipeline never hits
  # this because its pod is destroyed after every run.
  REAL_GPG=$(PATH=/usr/local/bin:/usr/bin:/bin command -v gpg || true)
  if [[ -n "$REAL_GPG" ]]; then
    printf '#!/bin/bash\nexec %s --batch "$@"\n' "$REAL_GPG" > /tmp/bin/gpg
    chmod +x /tmp/bin/gpg
  else
    echo "WARNING: FIPS node but no system gpg found; EnsureCleanState will hang on --import"
  fi
fi
# Cheap proof the above is sane -- a self-referential wrapper spins instead of returning.
timeout 10 gpg --version >/dev/null 2>&1 \
  || echo "WARNING: 'gpg --version' did not return in 10s -- $(command -v gpg) is broken"

# Since v3.x EnsureCleanState runs `goreman run status` before every test even in remote
# mode and fails when the binary is missing. Here the components are Deployments, so the
# stand-in reports nothing running and turns the sharding tests' restarts into rollouts.
if ! command -v goreman >/dev/null; then
  cat > /tmp/bin/goreman <<SHIM
#!/bin/bash
[[ "\$1" == run && "\$2" == start ]] || exit 0
case "\$3" in
  controller)  t=statefulset/${ARGOCD_E2E_APPLICATION_CONTROLLER_NAME} ;;
  api-server)  t=deployment/${ARGOCD_E2E_SERVER_NAME} ;;
  repo-server) t=deployment/${ARGOCD_E2E_REPO_SERVER_NAME} ;;
  redis)       t=deployment/${ARGOCD_E2E_REDIS_NAME} ;;
  *) exit 0 ;;
esac
kubectl rollout restart \$t -n ${ARGOCD_E2E_NAMESPACE} >&2 &&
  kubectl rollout status \$t -n ${ARGOCD_E2E_NAMESPACE} --timeout=5m >&2
SHIM
  chmod +x /tmp/bin/goreman
fi

# --- run -------------------------------------------------------------------------
# Upstream's `make start-e2e` creates these on every run and the fixture deliberately never
# does ("don't delete the namespace itself as it's shared"), so nothing inside the suite will
# put them back. Creating them only at setup left ~50 app-in-any-namespace tests failing with
# `namespaces "argocd-e2e-external" not found`. Never label them e2e.argoproj.io=true --
# EnsureCleanState deletes everything carrying that label.
for n in ${ARGOCD_APPLICATION_NAMESPACES//,/ }; do
  kubectl get ns "$n" >/dev/null 2>&1 || kubectl create ns "$n" >/dev/null
done

# Upstream's start-e2e-local also applies Open Cluster Management's PlacementDecision CRD, which
# the five ClusterDecisionResource generator tests read. Some clusters already carry it -- the
# FIPS 4.20 one had it from long before these runs -- but a fresh EKS cluster does not, and
# there all five failed with "the server could not find the requested resource". The URL comes
# from the checkout's own Makefile, so its pin moves with the Argo CD version.
if ! kubectl get crd placementdecisions.cluster.open-cluster-management.io >/dev/null 2>&1; then
  PD_CRD=$(grep -oE 'https://raw\.githubusercontent\.com/open-cluster-management/api/[^ ]+placementdecisions[^ ]*\.yaml' \
             "$SRC/Makefile" | head -1 || true)
  if [[ -n "$PD_CRD" ]] && kubectl apply -f "$PD_CRD" >/dev/null; then
    echo "Installed the PlacementDecision CRD (from upstream's Makefile)"
  else
    echo "WARNING: could not install the PlacementDecision CRD -- the ClusterDecisionResource tests will fail"
  fi
fi

cd "$SRC/test/e2e" || exit 1      # upstream convention; fixture paths are relative to it
getent hosts argocd-e2e-server >/dev/null || echo "WARNING: argocd-e2e-server does not resolve"
for t in "argocd:argocd version --client --short" "helm:helm version --short" \
         "kustomize:kustomize version"; do
  printf '%-11s %s\n' "${t%%:*}" \
    "$(eval "${t#*:}" 2>&1 | grep -m1 . || echo "(no output -- $(command -v "${t%%:*}" || echo 'not on PATH'))")"
done
MATCHED=$("$SRC/e2e.test" -test.list "${TEST_RUN_FILTER:-.}" 2>/dev/null | grep '^Test' || true)
N=$(printf '%s\n' "$MATCHED" | grep -c '^Test' || true)
echo "Filter /${TEST_RUN_FILTER:-.}/ matches ${N} test(s)"
# -test.run is an unanchored regex: TestCMP also matches TestCMPWithX, and a bare Test
# matches the whole suite. Anchor with ^...$ when you mean exactly one test.
if [[ "$N" -le 25 && "$N" -gt 0 ]]; then printf '  %s\n' $MATCHED; fi
[[ -z "${LIST_ONLY:-}" ]] || exit 0
[[ "$N" -gt 0 ]] || { echo "nothing to run"; exit 0; }
echo

# Remote mode diverges from upstream here. Locally RepoURL() is file://$TmpDir/testdata.git --
# the served repo *is* the directory EnsureCleanState wipes and `git init`s before every test,
# so every branch dies with it. In remote mode the runner only ever pushes master to the git
# server pod, and nothing in the fixture deletes a remote ref, so hydrator output (env/test,
# env/test-next, refs/notes/hydrator.metadata) survives across runs. TestHydrateTo then finds
# env/test already hydrated, syncs cleanly, and fails expecting OperationError.
# Tags are left alone: they are seeded into the served repo, not produced by tests.
STALE=$(git ls-remote "$ARGOCD_E2E_GIT_SERVICE" 2>/dev/null \
  | awk '$2 != "HEAD" && $2 != "refs/heads/master" && $2 !~ /^refs\/tags\// {print $2}')
if [[ -n "$STALE" ]]; then
  echo "Pruning refs an earlier run left on the git server:"
  printf '  %s\n' $STALE
  # shellcheck disable=SC2086
  git push "$ARGOCD_E2E_GIT_SERVICE" --delete $STALE >/dev/null 2>&1 \
    || echo "  WARNING: some refs could not be deleted"
  echo
fi

# One panic in the fixture takes the whole binary down -- a single nil deref in the hydrator
# tests truncated a full run at 395 of 503. ARGOCD_E2E_RECORD is upstream's own resume hook:
# every test that passes is appended, and SkipIfAlreadyRun skips anything already listed on
# the next start. The crashing test never records itself, so name it from the panic stack and
# bank it by hand, otherwise the resume panics in the same place forever.
RECORD=$W/tests-run.txt; CRASHED=$W/crashed.txt
rm -f "$RECORD" "$CRASHED" /tmp/last.log
export ARGOCD_E2E_RECORD="$RECORD"

rc=0
for attempt in $(seq 1 "${MAX_CRASH_RESUMES:-12}"); do
  if [[ $attempt -gt 1 ]]; then
    echo
    echo "=== CRASH DETECTED -- resuming (attempt ${attempt}), $(wc -l < "$RECORD") already passed"
    echo
  fi
  "$SRC/e2e.test" -test.v -test.timeout "${ARGOCD_E2E_TEST_TIMEOUT:-60m}" \
    ${TEST_RUN_FILTER:+-test.run "$TEST_RUN_FILTER"} \
    ${ARGOCD_E2E_SKIP:+-test.skip "$ARGOCD_E2E_SKIP"} 2>&1 | tee /tmp/attempt.log
  rc=${PIPESTATUS[0]}
  cat /tmp/attempt.log >> /tmp/last.log
  # go test exits 2 on a panic; 1 is an ordinary test failure and needs no resume.
  [[ $rc -eq 2 ]] || break
  c=$(sed -n '/^panic:/,$p' /tmp/attempt.log | grep -oE 'e2e\.Test[A-Za-z0-9_]+' | head -1 | cut -d. -f2)
  [[ -n "$c" ]] || c=$(grep -oE '^=== RUN   Test[A-Za-z0-9_]+' /tmp/attempt.log | awk 'END{print $3}')
  if [[ -z "$c" ]]; then echo "=== crashed but the test could not be named -- stopping"; break; fi
  echo "$c" >> "$RECORD"; echo "$c" >> "$CRASHED"
done

# Top-level only (Go indents subtest result lines), deduplicated by name across attempts: a
# resumed run re-reports earlier passes as SKIP, so counting raw lines would be wrong.
echo
for k in PASS FAIL SKIP; do
  grep -h "^--- ${k}: " /tmp/last.log | awk '{print $3}' | sort -u > "/tmp/res.${k}"
done
touch "$CRASHED"
comm -23 /tmp/res.FAIL /tmp/res.PASS | cat - "$CRASHED" | sort -u > /tmp/res.failed
comm -23 /tmp/res.SKIP /tmp/res.PASS | comm -23 - /tmp/res.failed > /tmp/res.skipped
printf '=== %s passed, %s failed, %s skipped (exit %s)\n' \
  "$(wc -l < /tmp/res.PASS)" "$(wc -l < /tmp/res.failed)" \
  "$(wc -l < /tmp/res.skipped)" "$rc"
while read -r n; do
  if grep -qx "$n" "$CRASHED"; then echo "--- CRASH: $n"; else echo "--- FAIL:  $n"; fi
done < /tmp/res.failed

# The counts publish-results.sh reads, written where the host can fetch them. Crashes are
# reported as errors rather than failures -- a test whose process died never returned a
# verdict, and lumping the two together hides whether a red run is product behaviour or the
# fixture falling over. failedTests carries both, since both are things to go and look at.
n_pass=$(wc -l < /tmp/res.PASS)
n_skip=$(wc -l < /tmp/res.skipped)
n_err=$(sort -u "$CRASHED" | grep -c . || true)
n_fail=$(comm -23 /tmp/res.failed <(sort -u "$CRASHED") | grep -c . || true)
{
  printf '{"total":%s,"passed":%s,"failed":%s,"skipped":%s,"errors":%s,"failedTests":[' \
    "$((n_pass + n_fail + n_err + n_skip))" "$n_pass" "$n_fail" "$n_skip" "$n_err"
  # Go test names are identifiers, but escape anyway rather than emit invalid JSON.
  sep=""
  while read -r n; do
    [[ -z "$n" ]] && continue
    printf '%s"%s"' "$sep" "$(printf '%s' "$n" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    sep=","
  done < /tmp/res.failed
  printf ']}\n'
} > "$W/test-results.json"

exit "$rc"
POD_SCRIPT
}

# --------------------------------------------------------------------- running ---

run_in_pod() {
  local skip_os=$SKIP_OPENSHIFT
  if [[ "$skip_os" == auto ]]; then
    if is_openshift; then skip_os=true; else skip_os=false; fi
  fi
  # Detached and polled: an oc exec held open for an hour through the API server's load
  # balancer drops, ending the run with the suite still going and its output lost.
  # Ctrl-C here detaches; `logs` comes back.
  oc exec -n "$NS" "$POD" -- env \
      ARGOCD_NAMESPACE="$NS" \
      BRANCH="${VERSION:-}" \
      TEST_RUN_FILTER="$1" \
      ARGOCD_E2E_SKIP="${ARGOCD_E2E_SKIP:-}" \
      SKIP_LOCAL_ONLY="${SKIP_LOCAL_ONLY:-true}" \
      ARGOCD_E2E_SKIP_GPG="$SKIP_GPG" \
      ARGOCD_E2E_SKIP_OPENSHIFT="$skip_os" \
      ARGOCD_E2E_TEST_TIMEOUT="$TIMEOUT" \
    bash -c "rm -f ${EXITF}; nohup bash -c 'bash ${W}/run.sh > ${LOG} 2>&1; echo \$? > ${EXITF}' >/dev/null 2>&1 &"
  follow
}

follow() {
  local off=0 chunk misses=0 rc
  chunk=$(mktemp)
  while true; do
    if oc exec -n "$NS" "$POD" -- tail -c +$((off + 1)) "$LOG" > "$chunk" 2>/dev/null; then
      misses=0
      if [[ -s "$chunk" ]]; then cat "$chunk"; off=$((off + $(wc -c < "$chunk"))); fi
    else
      misses=$((misses + 1))
      if [[ $misses -ge 20 ]]; then rm -f "$chunk"; echo "lost contact with ${POD}"; return 1; fi
    fi
    if rc=$(oc exec -n "$NS" "$POD" -- cat "$EXITF" 2>/dev/null) && [[ -n "$rc" ]]; then
      oc exec -n "$NS" "$POD" -- tail -c +$((off + 1)) "$LOG" 2>/dev/null || true
      rm -f "$chunk"; return 0
    fi
    sleep 5
  done
}

cmd_run() {
  [[ -n "$FILTER" ]] || die "give a test regex, e.g. '$0 run TestNamespacedOrphanedResource'"
  oc get pod "$POD" -n "$NS" >/dev/null 2>&1 || die "no ${POD} pod in ${NS} -- run '$0 setup' first"
  push_runner_script
  if [[ "$RECOMPILE" == true ]]; then
    say "Discarding the checkout; this run recompiles"
    oc exec -n "$NS" "$POD" -- rm -rf "$W/argo-cd"
  fi
  run_in_pod "$FILTER"
}

# ------------------------------------------------------------------------- ci ---
#
# One shot: deploy, compile, run everything, leave the counts where publish-results.sh
# will find them. No teardown -- hive-suite-leg destroys the cluster when the leg ends,
# and tearing down first would only slow that up and throw away a cluster worth debugging.
cmd_ci() {
  cmd_setup
  say "Running the full suite"
  run_in_pod ""

  # follow() returns 0 once the run finishes; the suite's own status is the file the pod
  # wrote when it exited. Without this the leg records every argocd-e2e run as a pass.
  local rc
  rc=$(oc exec -n "$NS" "$POD" -- cat "$EXITF" 2>/dev/null || echo "")
  [[ -n "$rc" ]] || { echo "ERROR: the run left no exit status in ${EXITF}"; return 1; }

  mkdir -p "$SHARED_DIR"
  if oc exec -n "$NS" "$POD" -- cat "$W/test-results.json" > "$SHARED_DIR/test-results.json" 2>/dev/null \
     && [[ -s "$SHARED_DIR/test-results.json" ]]; then
    say "Results: $(cat "$SHARED_DIR/test-results.json")"
  else
    # Leave no file rather than a misleading empty one: publish-results.sh omits the test
    # counts entirely when it cannot read this, which reads as "unknown" rather than "zero
    # failures". A zeroed file would publish a green row for a run that never reported.
    rm -f "$SHARED_DIR/test-results.json"
    echo "WARNING: the pod wrote no test-results.json; publishing without test counts"
  fi

  say "Suite exited ${rc}"
  return "$rc"
}

cmd_teardown() {
  # Strip Application finalizers first or the namespaces hang Terminating forever.
  for n in "$NS" argocd-e2e-external argocd-e2e-external-2; do
    oc get applications -n "$n" -o name 2>/dev/null \
      | xargs -n1 -I{} oc patch {} -n "$n" --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  done
  oc delete ns -l e2e.argoproj.io=true --ignore-not-found --wait=false 2>/dev/null || true
  oc delete ns argocd-e2e-external argocd-e2e-external-2 --ignore-not-found --wait=false 2>/dev/null || true
  if [[ "$ALL" == true ]]; then
    oc delete ns "$NS" --ignore-not-found --wait=false
    oc delete clusterrolebinding "argocd-e2e-${NS}-cluster-admin" --ignore-not-found >/dev/null
  else
    oc delete pod "$POD" -n "$NS" --ignore-not-found --wait=false
    echo "Argo CD in ${NS} left in place; --all removes it too."
  fi
}

case "$CMD" in
  ci)       cmd_ci ;;
  setup)    cmd_setup ;;
  run)      cmd_run ;;
  logs)     follow ;;
  list)     push_runner_script
            oc exec -n "$NS" "$POD" -- env ARGOCD_NAMESPACE="$NS" BRANCH="${VERSION:-}" \
              TEST_RUN_FILTER="${FILTER:-.}" SKIP_LOCAL_ONLY="${SKIP_LOCAL_ONLY:-true}" \
              LIST_ONLY=1 bash "${W}/run.sh" ;;
            # The bracket keeps each pattern from matching this very command line -- pkill
            # is happy to SIGKILL the shell running it, which is how it looks like a no-op.
  stop)     oc exec -n "$NS" "$POD" -- bash -c \
              "pkill -f '[e]2e[.]test'; pkill -9 -f '[b]in/gpg'; true"; echo "stopped" ;;
  shell)    oc exec -it -n "$NS" "$POD" -- bash -c "cd ${W}/argo-cd/test/e2e 2>/dev/null || cd ${W}; exec bash" ;;
  teardown) cmd_teardown ;;
  *)        die "unknown command '${CMD}' -- setup, run, list, logs, stop, shell, teardown" ;;
esac
