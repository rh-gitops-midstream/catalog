OS := $(shell uname | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
OCP_VERSIONS := 4.12 4.13 4.14 4.15 4.16 4.17 4.18 4.19
BIN_DIR := bin
OPM_VERSION := "v1.47.0"
OPM_FILENAME := opm-$(OPM_VERSION)
OPM_PATH := $(BIN_DIR)/$(OPM_FILENAME)
OPM := $(BIN_DIR)/opm

.PHONY: deps

deps:
	@mkdir -p $(BIN_DIR)
	@if [ ! -f "$(OPM_PATH)" ]; then \
		echo "Installing opm $(OPM_VERSION)..."; \
		curl -sSfLo $(OPM_PATH) "https://github.com/operator-framework/operator-registry/releases/download/$(OPM_VERSION)/$(OS)-$(ARCH)-opm"; \
		chmod +x $(OPM_PATH); \
	fi
	ln -fs $(OPM_FILENAME) $(OPM)

.PHONY: init-catalog-template
init-catalog-template: 
	@mkdir -p catalog-renders
	@echo "Setting up local registry to mirror images..."
	podman rm -f registry || true
	podman run --rm -d -p 5000:5000 --name registry registry:2

	@for version in $(OCP_VERSIONS); do \
		echo "Mirroring v$$version operator index image..."; \
		podman pull registry.redhat.io/redhat/redhat-operator-index:v$$version; \
		podman tag registry.redhat.io/redhat/redhat-operator-index:v$$version localhost:5000/redhat-operator-index:v$$version; \
		podman push localhost:5000/redhat-operator-index:v$$version --tls-verify=false; \
		echo "Extracting catalog for v$$version..."; \
		$(OPM) render --use-http localhost:5000/redhat-operator-index:v$$version -o yaml > catalog-renders/render-v$$version.yaml; \
	done

.PHONY: convert-to-basic-template
convert-to-basic-template:
	@for version in $(OCP_VERSIONS); do \
		echo "Converting rendered catalog for v$$version to basic template..."; \
		mkdir -p catalog/v$$version; \
		$(OPM) alpha convert-template basic catalog-renders/render-v$$version.yaml -o yaml > catalog/v$$version/template.yaml; \
	done

.PHONY: catalog-template
catalog-template: 
	python3 generate-catalog-template.py

.PHONY: catalog
# Detect platform and set SED_INPLACE accordingly
ifeq ($(shell uname), Darwin)
  SED_INPLACE = sed -i ''
else
  SED_INPLACE = sed -i
endif
catalog: deps
	@if [ -z "$(ocp)" ]; then \
		echo "Error: 'ocp' parameter is required. Usage: make catalog ocp=v4.14"; \
		exit 1; \
	fi; \
	version="$${ocp}"; \
	echo "Rendering catalog for $$version..."; \
	mkdir -p catalog/$$version/openshift-gitops-operator; \
	MAJOR=$$(echo $$version | cut -d. -f1 | sed 's/v//'); \
	MINOR=$$(echo $$version | cut -d. -f2); \
	if [ "$$MAJOR" -eq 4 ] && [ "$$MINOR" -ge 17 ]; then \
		MIGRATE="--migrate-level=bundle-object-to-csv-metadata"; \
	else \
		MIGRATE=""; \
	fi; \
	$(OPM) alpha render-template basic catalog/$$version/template.yaml $$MIGRATE -o yaml > catalog/$$version/openshift-gitops-operator/catalog.yaml; \
	ls -lh catalog/$$version/openshift-gitops-operator/catalog.yaml; \
	echo "Replacing quay.io with registry.redhat.io in $$version catalog..."; \
	$(SED_INPLACE) 's~quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-operator-bundle~registry.redhat.io/openshift-gitops-1/gitops-operator-bundle~g' catalog/$$version/openshift-gitops-operator/catalog.yaml