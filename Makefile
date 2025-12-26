SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-builtin-rules
.SUFFIXES:

# Project root = directory containing this Makefile
PROJECT_ROOT := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))
# Ignore host environment overrides for repo wiring.
undefine COMPOSE_FILE
undefine SERVICE
undefine SAGE_BIN
undefine SAGE_BASE_ARGS


# Select run config
CONFIG ?= config/shrikhande_r3.mk
include $(CONFIG)

# Resolve compose file absolute path (systemd-safe)
COMPOSE_FILE_ABS := $(abspath $(if $(filter /%,$(COMPOSE_FILE)),$(COMPOSE_FILE),$(PROJECT_ROOT)/$(COMPOSE_FILE)))
PODMAN_COMPOSE_ABS := $(abspath $(PROJECT_ROOT)/.venv/bin/podman-compose)



# Per-jobset state
STATE_DIR   := $(PROJECT_ROOT)/var/$(JOBSET)
QUEUE_DIR   := $(STATE_DIR)/queue
PENDING_DIR := $(QUEUE_DIR)/pending
RUNNING_DIR := $(QUEUE_DIR)/running
DONE_DIR    := $(QUEUE_DIR)/done
FAILED_DIR  := $(QUEUE_DIR)/failed
RUN_DIR     := $(STATE_DIR)/run
LOG_DIR     := $(STATE_DIR)/log

# systemd user env file (single active jobset at a time)
ENV_DIR  := $(HOME)/.config/sagequeue
ENV_FILE := $(ENV_DIR)/sagequeue.env

SYSTEMD_USER_DIR := $(HOME)/.config/systemd/user
UNITS := sagequeue-container.service sagequeue-recover.service sagequeue-recover.timer sagequeue@.service

.PHONY: help print-config check setup env install-systemd uninstall-systemd \
        enable disable start stop restart status journal logs progress \
        enqueue-stride enqueue-one retry-failed requeue-running \
        request-stop clear-stop purge-queue diag

help:
	awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_.-]+:.*##/{printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST) | sort

print-config: ## Show resolved config values.
	echo "CONFIG=$(CONFIG)"
	echo "PROJECT_ROOT=$(PROJECT_ROOT)"
	echo "JOBSET=$(JOBSET)"
	echo "GRAPH=$(GRAPH)"
	echo "RANK=$(RANK)"
	echo "STRIDE=$(STRIDE)"
	echo "WORKERS=$(WORKERS)"
	echo "SERVICE=$(SERVICE)"
	echo "COMPOSE_FILE=$(COMPOSE_FILE_ABS)"
	echo "SCRIPT_CONT=$(SCRIPT_CONT)"
	echo "STOP_FILE_CONT=$(STOP_FILE_CONT)"
	echo "STOP_FILE_HOST=$(STOP_FILE_HOST)"
	echo "LOG_PREFIX=$(LOG_PREFIX)"
	echo "SAGE_BASE_ARGS=$(SAGE_BASE_ARGS)"

check: ## Verify required commands/files exist.
	command -v podman >/dev/null
	command -v systemctl >/dev/null
	command -v journalctl >/dev/null
	command -v tee >/dev/null
	command -v find >/dev/null
	command -v flock >/dev/null
	test -f "$(COMPOSE_FILE_ABS)"
      	test -x "$(PODMAN_COMPOSE_ABS)"
	test -x "$(PROJECT_ROOT)/bin/sagequeue-worker.sh" || true
	echo "[ok] toolchain present and compose file found"

setup: ## Create queue/log/run directories for this jobset.
	mkdir -p "$(PENDING_DIR)" "$(RUNNING_DIR)" "$(DONE_DIR)" "$(FAILED_DIR)" "$(RUN_DIR)" "$(LOG_DIR)"

env: setup ## Write systemd EnvironmentFile at $(ENV_FILE) for the selected config.
	mkdir -p "$(ENV_DIR)"
	base_args='$(SAGE_BASE_ARGS)'
	esc_base_args="$${base_args//\"/\\\"}"
	cat >"$(ENV_FILE)" <<-EOF
	PROJECT_ROOT=$(PROJECT_ROOT)
	JOBSET=$(JOBSET)
	
	STATE_DIR=$(STATE_DIR)
	QUEUE_DIR=$(QUEUE_DIR)
	PENDING_DIR=$(PENDING_DIR)
	RUNNING_DIR=$(RUNNING_DIR)
	DONE_DIR=$(DONE_DIR)
	FAILED_DIR=$(FAILED_DIR)
	RUN_DIR=$(RUN_DIR)
	LOG_DIR=$(LOG_DIR)
	
	COMPOSE_FILE=$(COMPOSE_FILE_ABS)
	PODMAN_COMPOSE=$(PODMAN_COMPOSE_ABS)
	SERVICE=$(SERVICE)
	
	CONTAINER_WORKDIR=$(CONTAINER_WORKDIR)
	SAGE_BIN=$(SAGE_BIN)
	
	SCRIPT=$(SCRIPT_CONT)
	
	STOP_FILE_CONT=$(STOP_FILE_CONT)
	STOP_FILE_HOST=$(STOP_FILE_HOST)
	
	STRIDE=$(STRIDE)
	LOG_PREFIX=$(LOG_PREFIX)
	SLEEP_EMPTY=$(SLEEP_EMPTY)
	
	SAGE_BASE_ARGS="$$esc_base_args"
	EOF
	echo "[ok] wrote $(ENV_FILE)"

install-systemd: ## Install systemd user units from ./systemd into ~/.config/systemd/user
	mkdir -p "$(SYSTEMD_USER_DIR)"
	for u in $(UNITS); do \
	  install -m 0644 "$(PROJECT_ROOT)/systemd/$$u" "$(SYSTEMD_USER_DIR)/$$u"; \
	done
	systemctl --user daemon-reload
	echo "[ok] installed units to $(SYSTEMD_USER_DIR)"

uninstall-systemd: ## Remove systemd user units
	for u in $(UNITS); do rm -f "$(SYSTEMD_USER_DIR)/$$u"; done
	systemctl --user daemon-reload
	echo "[ok] removed units from $(SYSTEMD_USER_DIR)"

enable: check env install-systemd ## Enable + start container, recover timer, and WORKERS worker instances.
	systemctl --user enable --now sagequeue-container.service
	systemctl --user enable --now sagequeue-recover.timer
	for i in $$(seq 1 "$(WORKERS)"); do \
	  systemctl --user enable --now "sagequeue@$$i.service"; \
	done
	echo "[ok] enabled container + timer + $(WORKERS) workers"
	echo "If you want these to run after reboot without logging in:"
	echo "  loginctl enable-linger $$USER"

disable: ## Stop + disable workers, timer, container.
	for i in $$(seq 1 "$(WORKERS)"); do \
	  systemctl --user disable --now "sagequeue@$$i.service" || true; \
	done
	systemctl --user disable --now sagequeue-recover.timer || true
	systemctl --user disable --now sagequeue-container.service || true
	echo "[ok] disabled services"

start: check env ## Start container + recover + workers (does not enable).
	systemctl --user start sagequeue-container.service
	systemctl --user start sagequeue-recover.service
	for i in $$(seq 1 "$(WORKERS)"); do \
	  systemctl --user start "sagequeue@$$i.service"; \
	done
	echo "[ok] started"

stop: ## Stop workers (container can remain running).
	for i in $$(seq 1 "$(WORKERS)"); do \
	  systemctl --user stop "sagequeue@$$i.service" || true; \
	done
	echo "[ok] stopped workers"

restart: check env ## Restart workers (reload env/config).
	for i in $$(seq 1 "$(WORKERS)"); do \
	  systemctl --user restart "sagequeue@$$i.service"; \
	done
	echo "[ok] restarted workers"

status: ## Show systemd status + queue counts.
	systemctl --user --no-pager status sagequeue-container.service || true
	systemctl --user --no-pager status sagequeue-recover.timer || true
	for i in $$(seq 1 "$(WORKERS)"); do \
	  systemctl --user --no-pager status "sagequeue@$$i.service" || true; \
	done
	@$(MAKE) -s progress

journal: ## Follow systemd journal for workers.
	journalctl --user -u 'sagequeue@*.service' -f

logs: ## Tail job logs under ./var/<JOBSET>/log/
	ls -1 "$(LOG_DIR)"/*.log >/dev/null 2>&1 || { echo "[ok] no logs yet in $(LOG_DIR)"; exit 0; }
	tail -n 80 -f "$(LOG_DIR)"/*.log

progress: ## Queue counts.
	p=$$(find "$(PENDING_DIR)" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
	r=$$(find "$(RUNNING_DIR)" -maxdepth 1 -type f -name '*.env' 2>/dev/null | wc -l | tr -d ' ')
	d=$$(find "$(DONE_DIR)" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
	f=$$(find "$(FAILED_DIR)" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
	t=$$((p+r+d+f))
	echo "jobset=$(JOBSET) pending=$$p running=$$r done=$$d failed=$$f total=$$t"

diag: ## Diagnostic snapshot (queue + systemd + container + solver procs).
	ENV_FILE="$(ENV_FILE)" "$(PROJECT_ROOT)/bin/sagequeue-diag.sh"

enqueue-stride: setup clear-stop ## Enqueue OFFSET=0..STRIDE-1 as durable jobs.
	for ((k=0;k<$(STRIDE);k++)); do \
	  base="$(JOBSET)_off$$k.env"; \
	  pend="$(PENDING_DIR)/$$base"; run="$(RUNNING_DIR)/$$base"; donef="$(DONE_DIR)/$$base"; fail="$(FAILED_DIR)/$$base"; \
	  if [[ -f "$$pend" || -f "$$run" ]]; then \
	    echo "[skip] $$base already queued/running"; \
	    continue; \
	  fi; \
	  if [[ -f "$$donef" || -f "$$fail" ]]; then \
	    if [[ "$(FORCE)" == "1" ]]; then rm -f "$$donef" "$$fail"; else echo "[skip] $$base already completed (use FORCE=1 to redo)"; continue; fi; \
	  fi; \
	  printf 'OFFSET=%s\nENQUEUED_AT=%s\n' "$$k" "$$(date -Is 2>/dev/null || date)" >"$$pend"; \
	  echo "[ok] enqueued $$base"; \
	done

enqueue-one: setup ## Enqueue one offset: make CONFIG=... enqueue-one OFFSET=3
	: "$${OFFSET:?set OFFSET=...}"
	base="$(JOBSET)_off$${OFFSET}.env"
	pend="$(PENDING_DIR)/$$base"; run="$(RUNNING_DIR)/$$base"
	donef="$(DONE_DIR)/$$base"; fail="$(FAILED_DIR)/$$base"
	if [[ -f "$$pend" || -f "$$run" ]]; then echo "[skip] $$base already queued/running"; exit 0; fi
	printf 'OFFSET=%s\nENQUEUED_AT=%s\n' "$${OFFSET}" "$$(date -Is 2>/dev/null || date)" >"$$pend"
	echo "[ok] enqueued $$base"

retry-failed: setup ## Move all failed jobs back to pending.
	shopt -s nullglob
	n=0
	for f in "$(FAILED_DIR)"/*.env; do \
	  base="$$(basename "$$f")"; \
	  mv -f "$$f" "$(PENDING_DIR)/$$base"; \
	  n=$$((n+1)); \
	done
	echo "[ok] requeued failed: $$n"

requeue-running: setup ## Move all running jobs back to pending (manual recovery).
	shopt -s nullglob
	n=0
	for f in "$(RUNNING_DIR)"/*.env; do \
	  base="$$(basename "$$f")"; \
	  rm -f "$$f.owner" 2>/dev/null || true; \
	  mv -f "$$f" "$(PENDING_DIR)/$$base"; \
	  n=$$((n+1)); \
	done
	echo "[ok] requeued running: $$n"

request-stop: ## Touch the stop file on the host (workers stop claiming new jobs; Sage sees it via bind mount).
	mkdir -p "$$(dirname "$(STOP_FILE_HOST)")"
	touch "$(STOP_FILE_HOST)"
	echo "[ok] touched $(STOP_FILE_HOST)"

clear-stop: ## Remove the stop file on the host.
	rm -f "$(STOP_FILE_HOST)" 2>/dev/null || true
	echo "[ok] cleared stop file"

purge-queue: setup ## Destructively clear pending/running/done/failed for the active jobset.
	rm -f "$(PENDING_DIR)"/* "$(RUNNING_DIR)"/* "$(DONE_DIR)"/* "$(FAILED_DIR)"/* 2>/dev/null || true
	rm -f "$(RUNNING_DIR)"/*.owner 2>/dev/null || true
	echo "[ok] purged queue for $(JOBSET)"

