# Convenience wrapper around the shell scripts. The scripts remain fully usable
# directly (e.g. ./install.sh); this Makefile just provides memorable targets.
SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help install status test diagnose destroy bootstrap resolve lint clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

install: ## Full host preflight + VM + provision + validate
	./install.sh

status: ## Report Vagrant/VM/K3s/AWX health and the AWX URL
	./status.sh

test: ## Run static checks + live integration tests
	./test.sh

diagnose: ## Collect a redacted diagnostic bundle
	./diagnose.sh

destroy: ## Destroy ONLY this project's VM (requires --yes)
	./destroy.sh --yes

bootstrap: ## Run only the host bootstrap (deps, plugin, utility, venv)
	./scripts/bootstrap-host.sh

resolve: ## Refresh versions.yml from live upstream APIs
	./scripts/resolve-versions.sh

lint: ## Static tests only
	./tests/static.sh

clean: ## Remove transient caches/artifacts (keeps .state secrets and the VM)
	rm -rf .artifacts/* .cache/* inventory/generated/hosts.ini 2>/dev/null || true
	@echo "Cleaned caches/artifacts. VM and .state/ secrets preserved."
