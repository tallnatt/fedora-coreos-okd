SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

SCRIPTS_DIR := $(CURDIR)/scripts

.PHONY: help configure-cluster check-deps select-topology select-network configure-nodes download network ignition overlays vms finish install status destroy rollback

help: ## Show available targets
	@echo "OKD on Fedora CoreOS (libvirt) Automation"
	@echo ""
	@echo "Usage: make <target> [TOPOLOGY=standard|compact|sno] [NETWORK_MODE=nat|bridge]"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

configure-cluster: ## Prompt for cluster name, domain, OKD/FCOS versions, SSH key, and libvirt paths
	@$(SCRIPTS_DIR)/00-configure-cluster.sh

check-deps: ## Verify required host tools (and prompt to install missing OS packages)
	@$(SCRIPTS_DIR)/01-check-deps.sh

select-topology: ## Prompt for cluster topology (standard, compact, or sno)
	@$(SCRIPTS_DIR)/00-select-topology.sh

select-network: ## Prompt for networking mode (nat or bridge) and required network settings
	@$(SCRIPTS_DIR)/00-select-network.sh

configure-nodes: ## Prompt for VM name, overlay file, disk, vCPU, and memory per node (with recommended defaults)
	@$(SCRIPTS_DIR)/00-configure-nodes.sh

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

install: configure-cluster select-topology select-network configure-nodes check-deps download network ignition overlays vms finish ## Run the full end-to-end OKD installation

status: ## Show libvirt VM status and OKD cluster node/operator status
	@virsh --connect "$${LIBVIRT_URI:-qemu:///system}" list --all
	@if [[ -f "$(CURDIR)/work/okd/auth/kubeconfig" ]]; then \
		echo ""; \
		KUBECONFIG="$(CURDIR)/work/okd/auth/kubeconfig" oc get nodes || true; \
		echo ""; \
		KUBECONFIG="$(CURDIR)/work/okd/auth/kubeconfig" oc get co || true; \
	fi

destroy: ## Destroy cluster VMs, overlays, and network (preserves cached base images/tools)
	@$(SCRIPTS_DIR)/destroy.sh

rollback: ## Full rollback: delete cluster, remove cached images/tools, and restore host config
	@$(SCRIPTS_DIR)/rollback.sh
