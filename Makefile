# Kramerius Helm chart — local dev.
# Optional: set GATEWAY_MANAGER_PORT / SLACK_SIGNING_SECRET, then:
#   make run

CHART_ROOT  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
DEV_DIR     := $(CHART_ROOT)dev
RUN_DIR     := $(CHART_ROOT).run

.PHONY: default run stop logs

default: run

run:
	docker compose -f $(DEV_DIR)/docker-compose.dev.yaml up --build -d

stop:
	docker compose -f $(DEV_DIR)/docker-compose.dev.yaml down

logs:
	docker compose -f $(DEV_DIR)/docker-compose.dev.yaml logs -f
