# Keystone Makefile — task runner for common Terraform workflows.
#
# Read this top-to-bottom; it's short on purpose. The boilerplate that
# every per-layer command needs (source secrets, export TF_VAR_*,
# terraform init with backend-config) is in scripts/_tf-cmd.sh.
#
# Usage:
#   make                            # same as `make help`
#   make help                       # list available targets
#   make plan-30-connectivity       # plan a specific platform layer
#   make apply-20-management        # apply a specific platform layer
#   make vend-sub ALIAS=...         # vend a Phase-2 sub + reconcile MGs
#   make cost                       # MTD cost snapshot
#   make destroy-platform           # destroy 40→30→20→10 (NEVER 05 or 00)
#
# The Makefile does NOT replace raw `terraform` — it's a shortcut for
# the workflows we run repeatedly. For ad-hoc work (-target, taint,
# state-rm, etc.) you still cd into the layer and use terraform directly.

.DEFAULT_GOAL := help
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: help cost fmt vend-sub destroy-platform destroy-workload

# Suppress the line-by-line command echo; targets are responsible for
# their own output.
.SILENT:

# -- General -----------------------------------------------------------------

help:  ## Show available targets
	printf "Keystone Makefile — common targets:\n\n"
	grep -hE '^[a-z][a-z0-9_-]*(-%)?:.*## ' $(MAKEFILE_LIST) \
		| sort \
		| awk -F':.*## ' '{printf "  \033[1m%-30s\033[0m %s\n", $$1, $$2}'
	printf "\nPattern rules:\n"
	printf "  \033[1mplan-LAYER\033[0m                     Plan a platform layer (e.g. plan-30-connectivity)\n"
	printf "  \033[1mapply-LAYER\033[0m                    Apply a platform layer\n"
	printf "\n"

cost:  ## Show MTD Azure spend per subscription (MCA billing profile scope)
	source ~/.keystone/secrets.env && ./scripts/cost-snapshot.sh

fmt:  ## terraform fmt -recursive across platform/
	terraform fmt -recursive platform/

# -- Per-layer pattern rules -------------------------------------------------
#
# Pattern rule stem ($*) is the layer name, e.g. "30-connectivity".
# All the env / init / backend-config dance is delegated to the helper.
# Add a new layer? Just put the .tf files in platform/<name>/ — these
# rules pick it up automatically without touching the Makefile.

plan-%:  ## (see "Pattern rules" below)
	./scripts/_tf-cmd.sh "$*" plan

apply-%:  ## (see "Pattern rules" below)
	./scripts/_tf-cmd.sh "$*" apply

# -- Cross-layer workflows ---------------------------------------------------

vend-sub:  ## Vend a Phase-2 sub and reconcile every downstream layer that for_each'es over subscriptions. Usage: make vend-sub ALIAS=platform-identity
	test -n "$(ALIAS)" || { echo "ERROR: set ALIAS=<sub-alias> (e.g. platform-identity, reelhouse-dev)"; exit 2; }
	echo "─── Vending $(ALIAS) in 05-subscriptions ───"
	./scripts/_tf-cmd.sh 05-subscriptions apply -auto-approve \
		-var=vend_phase=phase-2 \
		-target='azurerm_subscription.this["$(ALIAS)"]'
	echo
	echo "─── Reconciling MG associations in 10-management-groups ───"
	./scripts/_tf-cmd.sh 10-management-groups apply -auto-approve
	echo
	echo "─── Reconciling budgets + cost exports in 20-management ───"
	echo "(Cost-export may fail on a freshly-vended sub — Microsoft takes up to 24h"
	echo " to enable cost-data API for new MCA subs. Retry tomorrow if so.)"
	./scripts/_tf-cmd.sh 20-management apply -auto-approve || \
		{ echo "WARN: 20-management apply failed (expected if sub is <24h old). Retry tomorrow with: make apply-20-management"; }
	echo
	echo "Done. Capture the new sub ID into ~/.keystone/secrets.env as"
	echo "KEYSTONE_PLATFORM_$$(echo "$(ALIAS)" | tr 'a-z-' 'A-Z_')_SUBSCRIPTION_ID"
	echo "(or KEYSTONE_REELHOUSE_<ENV>_SUBSCRIPTION_ID for workload subs)."
	echo
	echo "When 40-identity lands, add it to this target's chain (it will"
	echo "have the same for_each-over-subs pattern)."

# -- Destroy targets ---------------------------------------------------------
#
# CLAUDE.md §7 is non-negotiable: NO destroy target may touch
# platform/05-subscriptions or platform/00-bootstrap. The platform
# subscriptions are long-lived; cancelling an MCA sub costs 90 days
# of quota.

destroy-platform:  ## Destroy 40→30→20→10 in reverse order. NEVER touches 05 or 00.
	echo "Destroying platform layers in reverse order (40 → 30 → 20 → 10)."
	echo "EXCLUDED per CLAUDE.md §7: 05-subscriptions, 00-bootstrap."
	echo
	for layer in 40-identity 30-connectivity 20-management 10-management-groups; do \
		if [ -d "platform/$$layer" ] && ls platform/$$layer/*.tf >/dev/null 2>&1; then \
			echo "─── Destroying $$layer ───"; \
			./scripts/_tf-cmd.sh "$$layer" destroy -auto-approve || \
				{ echo "FAILED on $$layer — STOPPING. Investigate before retrying."; exit 1; }; \
		else \
			echo "─── Skipping $$layer (not present) ───"; \
		fi; \
	done

destroy-workload:  ## Destroy workloads/reelhouse/*. (Stub — workload layer doesn't exist yet)
	echo "ERROR: workloads/reelhouse doesn't exist yet — nothing to destroy."
	exit 1
