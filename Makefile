TF_DIR := cloud
KEY_FILE := $(TF_DIR)/id_rsa.pem
SSH_USER := ubuntu
GET_IP = $(shell cd $(TF_DIR) && terraform output -raw public_ip)

include ./local/.env
export

# --- Cloud Targets ---

.PHONY: cloud-ip
cloud-ip: ## Output the public IP of the Lightsail instance
	@echo "$(GET_IP)"

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

.PHONY: cloud-force-refresh
cloud-force-refresh: ## Force the cloud gateway to update status
	@echo "Forcing status refresh on $(GET_IP)..."
	ssh -o "StrictHostKeyChecking=no" -i $(KEY_FILE) $(SSH_USER)@$(GET_IP) "sudo /usr/local/bin/healthcheck.sh"

# --- Local & Minecraft Targets ---

.PHONY: local-up
local-up: ## Start local Minecraft, Backup & Tunnel
	cd local && docker compose up -d
	$(MAKE) cloud-force-refresh


.PHONY: mc-backup
mc-backup: ## Create a manual pre-update tarball of the world and configs
	@echo "Creating pre-update backup for $(DATA_FOLDER)..."
	# Using RCON to force a world save before backup
	cd local && docker compose exec -i minecraft rcon-cli save-all
	sleep 5
	mkdir -p "./local/manual-backups"
	@echo "Archiving data stream. Please wait..."
	@if command -v pv >/dev/null 2>&1; then \
		echo "Using pv for progress monitoring..."; \
		tar -czf - "./local/instances/$(DATA_FOLDER)" | pv -treb > "./local/manual-backups/backup_$$(date +%Y%m%d_%H%M%S).tar.gz"; \
	else \
		echo "pv not found. Running standard verbose backup..."; \
		tar -czvf "./local/manual-backups/backup_$$(date +%Y%m%d_%H%M%S).tar.gz" "./local/instances/$(DATA_FOLDER)"; \
	fi

.PHONY: mc-update
mc-update: mc-backup ## Backup, pull latest image, and restart MC (triggers modpack update)
	@echo "Pulling latest image and restarting..."
	cd local && docker compose pull minecraft
	cd local && docker compose up -d
	@echo "Update triggered. Monitor with 'make mc-logs'"

.PHONY: mc-logs
mc-logs: ## View logs for the Minecraft server
	cd local && docker compose logs -f minecraft

.PHONY: mc-players
mc-players: ## List currently online players
	cd local && docker compose exec -i minecraft rcon-cli list

.PHONY: mc-playtime
mc-playtime: ## Calculate and display total playtime for all players
	@echo "Fetching player playtime statistics..."
	@for file in "./local/instances/$(DATA_FOLDER)/world/stats/"*.json; do \
		if [ -f "$$file" ]; then \
			uuid=$$(basename "$$file" ".json"); \
			ticks=$$(jq -r ".stats.\"minecraft:custom\".\"minecraft:play_time\" // empty" "$$file"); \
			if [ -n "$$ticks" ]; then \
				hours=$$(awk "BEGIN {printf \"%.2f\", $$ticks / 72000}"); \
				name=$$(curl -s "https://sessionserver.mojang.com/session/minecraft/profile/$$uuid" | jq -r ".name" 2>/dev/null); \
				if [ -z "$$name" ] || [ "$$name" = "null" ]; then name="$$uuid"; fi; \
				printf "\033[36m%-20s\033[0m %s hours\n" "$$name" "$$hours"; \
			fi; \
		fi; \
	done

.PHONY: frpc-logs
frpc-logs: ## View logs for local frpc
	cd local && docker compose logs -f frpc

.PHONY: deploy-modpack
deploy-modpack: ## Build and upload the client modpack zip to Caddy
	cd local && bash build-modpack.sh

# --- Utilities ---

.PHONY: help
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
