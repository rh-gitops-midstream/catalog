# Catalog

## Update catalog

```
bin/opm alpha render-template basic catalog/v4.12/catalog-template.yaml -o yaml > catalog/v4.12/openshift-gitops-operator/catalog.yaml 
```

## How initial catalog template was created ?

```bash
docker run -d -p 5000:5000 --name registry registry:2
```

```bash
podman pull registry.redhat.io/redhat/redhat-operator-index:v4.12
podman tag registry.redhat.io/redhat/redhat-operator-index:v4.12 localhost:5000/redhat-operator-index:v4.12
podman push localhost:5000/redhat-operator-index:v4.12 --tls-verify=false
```

```bash
bin/opm render --use-http localhost:5000/redhat-operator-index:v4.12 -o yaml > catalog-render-4.12.yaml

# Clean up the render by removing none gitops-operator entires

# https://olm.operatorframework.io/docs/reference/catalog-templates/#converting-from-fbc-to-basic-template
# create a template
bin/opm alpha convert-template basic catalog-render-4.12.yaml -o yaml > catalog-4.12-basic-template.yaml
```


