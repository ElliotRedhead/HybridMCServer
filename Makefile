TF_DIR := cloud
KEY_FILE := $(TF_DIR)/id_rsa.pem
SSH_USER := ubuntu
GET_IP = $(shell cd $(TF_DIR) && terraform output -raw public_ip)

# Cloud

.PHONY: cloud-ssh
cloud-ssh: ## SSH into the Lightsail instance
	@echo "Connecting to $(GET_IP)..."
	ssh -i $(KEY_FILE) $(SSH_USER)@$(GET_IP)

.PHONY: cloud-deploy
cloud-deploy: ## Apply Terraform changes (Auto-Approve)
	cd $(TF_DIR) && terraform apply -auto-approve

.PHONY: cloud-force-deploy
cloud-force-deploy: ## Force recreate the instance
	cd $(TF_DIR) && terraform taint aws_lightsail_instance.vpn_proxy
	cd $(TF_DIR) && terraform apply -auto-approve

# Local

.PHONY: local-up
local-up: ## Start local Minecraft, Backup & Tunnel
	cd local && docker-compose up -d

.PHONY: frpc-logs
frpc-logs: ## View logs for local frpc
	cd local && docker-compose logs -f frpc

.PHONY: help
help: ### Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'