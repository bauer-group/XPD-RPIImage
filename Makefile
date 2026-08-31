# BAUER GROUP XPD-RPIImage - Makefile wrapper
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

VARIANT ?= canbus-plattform
CONFIG  := config/variants/$(VARIANT).json
ENV_FILE ?=

PY := python3
PIP := $(PY) -m pip

.PHONY: help
help: ## show this help
	@awk 'BEGIN{FS=":.*##"; printf "targets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: deps
deps: ## install Python dev deps
	$(PIP) install -r scripts/requirements.txt

.PHONY: validate
validate: ## validate the JSON variant against the schema (no rendering)
	$(PY) scripts/generate.py $(CONFIG) $(if $(ENV_FILE),--env-file $(ENV_FILE),) --dry-run > /dev/null
	@echo "ok: $(CONFIG) valid"

.PHONY: render
render: ## resolve env vars + render generated module files
	$(PY) scripts/generate.py $(CONFIG) $(if $(ENV_FILE),--env-file $(ENV_FILE),)

.PHONY: bootstrap
bootstrap: ## clone/update CustomPiOS into ./CustomPiOS
	bash scripts/bootstrap.sh

.PHONY: build
build: render bootstrap ## build the image for $(VARIANT) (needs docker + privileged)
	bash scripts/build.sh $(if $(ENV_FILE),--env-file $(ENV_FILE),) $(VARIANT)

.PHONY: clean
clean: ## remove generated module files and build workspace
	@# generate.py renders into filesystem/root/opt/bgrpiimage/<module>, not
	@# into a _generated/ directory - the old pattern matched nothing.
	@rm -rf src/modules/*/filesystem/root/opt/bgrpiimage
	@# build_dist creates workspace-<variant> for every non-default variant;
	@# plain src/workspace only exists for the "default" variant.
	@rm -rf src/workspace src/workspace-* dist
	@# generated at build time by scripts/build.sh / update-custompios-paths
	@rm -f src/config.local src/custompios_path src/build.log
	@# generated variant configs (gitignored build output, see .gitignore)
	@rm -f src/variants/*/config
	@echo "cleaned (base image cache kept - use distclean to drop it)"

.PHONY: distclean
distclean: clean ## also remove CustomPiOS checkout and the base image cache
	@rm -rf CustomPiOS src/image-cache
	@echo "distcleaned"
