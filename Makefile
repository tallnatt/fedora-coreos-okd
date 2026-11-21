SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

SCRIPTS_DIR := $(CURDIR)/scripts

.PHONY: help check-deps select-topology select-network download network ignition overlays vms finish install status destroy

help: ## Show available targets
	@echo "OKD on Fedora CoreOS (libvirt) Automation"
	@echo ""
	@echo "Usage: make <target> [TOPOLOGY=standard|compact|sno] [NETWORK_MODE=nat|bridge]"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

check-deps: ## Verify required host tools (virsh, virt-install, qemu-img, butane, openshift-install, oc, haproxy)
	@$(SCRIPTS_DIR)/01-check-deps.sh

select-topology: ## Prompt for cluster topology (standard, compact, or sno)
	@$(SCRIPTS_DIR)/00-select-topology.sh

select-network: ## Prompt for networking mode (nat or bridge)
	@$(SCRIPTS_DIR)/00-select-network.sh

download: ## Download Fedora CoreOS base image (and OKD tools if missing)
	@$(SCRIPTS_DIR)/02-download-assets.sh

network: ## Configure libvirt NAT network (dnsmasq DNS/DHCP) or verify host bridge, and configure HAProxy
	@$(SCRIPTS_DIR)/03-setup-network.sh

ignition: ## Generate OKD ignition configs and compile per-node Ignition files with Butane
	@$(SCRIPTS_DIR)/04-generate-ignition.sh

overlays: ## Create qcow2 copy-on-write overlays for each node
	@$(SCRIPTS_DIR)/05-create-overlays.sh

vms: ## Provision and boot Fedora CoreOS VMs in libvirt
	@$(SCRIPTS_DIR)/06-provision-vms.sh

finish: ## Wait for bootstrap, destroy bootstrap VM, approve CSRs, and wait for install-complete
	@$(SCRIPTS_DIR)/07-finish-install.sh

install: check-deps select-topology select-network download network ignition overlays vms finish ## Run the full end-to-end OKD installation

status: ## Show libvirt VM status and OKD cluster node/operator status
	@virsh --connect "$${LIBVIRT_URI:-qemu:///system}" list --all
	@if [[ -f "$(CURDIR)/work/okd/auth/kubeconfig" ]]; then \
		echo ""; \
		KUBECONFIG="$(CURDIR)/work/okd/auth/kubeconfig" oc get nodes || true; \
		echo ""; \
		KUBECONFIG="$(CURDIR)/work/okd/auth/kubeconfig" oc get co || true; \
	fi

destroy: ## Destroy all cluster VMs, qcow2 overlays, libvirt network, and generated artifacts
	@$(SCRIPTS_DIR)/destroy.sh
