OS := $(shell uname | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
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

