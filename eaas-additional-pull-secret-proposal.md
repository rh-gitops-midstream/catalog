# Proposal: Add `additionalPullSecret` parameter to `hypershift-aws-template`

## Problem

When deploying operators from private registries (e.g. Konflux-built images on `quay.io/redhat-user-workloads/`) onto EaaS ephemeral HyperShift clusters, workload pods fail with `ImagePullBackOff` because the cluster nodes lack pull credentials for those registries.

The existing `imageContentSources` parameter correctly configures IDMS (ImageDigestMirrorSet) so CRI-O knows *where* to pull from, but the nodes have no *credentials* for the mirror registries.

### Why post-provisioning injection doesn't work

On HyperShift clusters, modifying the global pull-secret (`openshift-config/pull-secret`) after provisioning does not propagate to worker nodes quickly enough. The hosted control plane's node config controller must roll out the change, which can take 10+ minutes — by which time operator workload pods have already failed.

Linking `imagePullSecrets` to individual ServiceAccounts is a workaround, but it's fragile: it requires knowing which SAs the operator creates, and must race against pod scheduling.

### Why the fix belongs at cluster creation time

The `hypershift create cluster aws --pull-secret` flag bakes credentials into every node at provisioning time. If the additional registry credentials are included in this pull secret, they are available on all nodes from the moment the cluster is ready — no propagation delay, no SA-level workarounds.

## Proposed change

Add an `additionalPullSecret` parameter to the `hypershift-aws-template` Helm chart. When set, the create-cluster job merges it with the default pull secret before passing it to `hypershift create cluster aws`.

### Schema change (`values.schema.json`)

Add a new optional property:

```json
"additionalPullSecret": {
  "type": "string",
  "description": "Additional pull secret in dockerconfigjson format (JSON string). Merged with the default pull secret before cluster creation."
}
```

### Values change (`values.yaml`)

```yaml
additionalPullSecret: ""
```

### Template change (`templates/create-cluster-job.yaml`)

Add an init container that merges the pull secrets:

```yaml
initContainers:
  # ... existing aws-sts init container ...
  {{- if .Values.additionalPullSecret }}
  - name: merge-pull-secret
    image: "{{ .Values.hypershiftImage }}"
    # ... security context, resources ...
    volumeMounts:
      - name: secret
        mountPath: /opt/hypershift/secret
      - name: merged-pull-secret
        mountPath: /opt/hypershift/merged
    command: ["/bin/sh"]
    args:
      - -ec
      - |
        python3 -c "
        import json
        with open('/opt/hypershift/secret/pull-secret') as f:
            base = json.load(f)
        extra = json.loads('''{{ .Values.additionalPullSecret }}''')
        base.setdefault('auths', {}).update(extra.get('auths', {}))
        with open('/opt/hypershift/merged/pull-secret', 'w') as f:
            json.dump(base, f)
        "
  {{- end }}
```

Update the main container to use the merged pull secret when available:

```yaml
- --pull-secret
{{- if .Values.additionalPullSecret }}
- /opt/hypershift/merged/pull-secret
{{- else }}
- /opt/hypershift/secret/pull-secret
{{- end }}
```

Add the volume:

```yaml
volumes:
  # ... existing volumes ...
  - name: merged-pull-secret
    emptyDir: {}
```

## EaaS step action change (`konflux-ci/build-definitions`)

Add `additionalPullSecret` and `additionalPullSecretFile` parameters to the `eaas-create-ephemeral-cluster-hypershift-aws` step action, mirroring the existing `imageContentSources` / `imageContentSourcesFile` pattern:

```yaml
params:
  # ... existing params ...
  - name: additionalPullSecret
    type: string
    default: ""
    description: >-
      Additional pull secret in dockerconfigjson format (JSON string).
      Merged with the default pull secret before cluster creation.
  - name: additionalPullSecretFile
    type: string
    default: ""
    description: >-
      Path to a file containing additional pull secret in dockerconfigjson format.
      If set, takes precedence over inline additionalPullSecret.
```

And in the script, resolve and inject it the same way `imageContentSources` is handled:

```bash
APS_VALUE=""
if [[ -n "$ADDITIONAL_PULL_SECRET_FILE" ]]; then
  if [[ -f "$ADDITIONAL_PULL_SECRET_FILE" ]]; then
    APS_VALUE="$(cat "$ADDITIONAL_PULL_SECRET_FILE")"
  else
    echo "ERROR: additionalPullSecretFile not found: $ADDITIONAL_PULL_SECRET_FILE" >&2
    exit 1
  fi
elif [[ -n "$ADDITIONAL_PULL_SECRET" ]]; then
  APS_VALUE="$ADDITIONAL_PULL_SECRET"
fi

export APS_VALUE
if [[ -n "$APS_VALUE" ]]; then
  yq -i '.spec.parameters += {"name": "additionalPullSecret", "value": strenv(APS_VALUE)}' cti.yaml
fi
```

## Usage from our pipeline

Once both changes land, our `provision-cluster` task would pass the pull secret at cluster creation:

```yaml
- name: create-cluster
  ref:
    resolver: git
    params:
      - name: url
        value: https://github.com/konflux-ci/build-definitions.git
      - name: revision
        value: main
      - name: pathInRepo
        value: stepactions/eaas-create-ephemeral-cluster-hypershift-aws/0.1/eaas-create-ephemeral-cluster-hypershift-aws.yaml
  params:
    - name: eaasSpaceSecretRef
      value: $(tasks.provision-eaas-space.results.secretRef)
    - name: imageContentSourcesFile
      value: "/workspace/imageContentSources.json"
    - name: additionalPullSecretFile
      value: "/workspace/additionalPullSecret.json"
    # ... other params ...
```

And a preceding step would prepare the file:

```yaml
- name: prepare-pull-secret
  image: $(tasks.build-ginkgo-test-image.results.IMAGE_URL)
  volumeMounts:
    - name: quay-pull-credentials
      mountPath: /quay-pull-credentials
      readOnly: true
  script: |
    #!/bin/bash
    cp /quay-pull-credentials/.dockerconfigjson /workspace/additionalPullSecret.json
```

This eliminates all post-provisioning pull-secret injection, SA linking, and pod restart logic from the install script.
