#!/usr/bin/env bash
#
# scripts/_tf-cmd.sh — internal Makefile helper.
#
# Wraps the per-layer boilerplate every platform/* layer needs to run a
# `terraform plan` / `apply` / `destroy`:
#   - source ~/.keystone/secrets.env
#   - export the TF_VAR_* env vars each layer might need
#   - terraform init -reconfigure with the right -backend-config args
#   - finally invoke terraform with the requested subcommand
#
# Not intended to be called by humans — the Makefile invokes it. Lives
# in scripts/ with an underscore prefix to flag "internal."
#
# Usage:
#   ./scripts/_tf-cmd.sh <layer> <terraform-subcommand> [args...]
#
# Examples:
#   ./scripts/_tf-cmd.sh 30-connectivity plan
#   ./scripts/_tf-cmd.sh 20-management apply -auto-approve
#   ./scripts/_tf-cmd.sh 05-subscriptions apply -auto-approve \
#       -var=vend_phase=phase-2 \
#       -target='azurerm_subscription.this["platform-identity"]'

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "ERROR: usage: $0 <layer> <terraform-subcommand> [args...]" >&2
  exit 2
fi

layer="$1"
cmd="$2"
shift 2

layer_dir="platform/${layer}"
if [[ ! -d "$layer_dir" ]]; then
  echo "ERROR: layer directory not found: $layer_dir" >&2
  exit 2
fi

# --- Load secrets + export every TF_VAR_* a platform layer might need ------

if [[ ! -f ~/.keystone/secrets.env ]]; then
  echo "ERROR: ~/.keystone/secrets.env not found." >&2
  echo "       See secrets.example.env for the template." >&2
  exit 2
fi

# shellcheck disable=SC1090
source ~/.keystone/secrets.env

# Every layer needs at least tenant_id. The rest are layer-specific, but
# Terraform only complains about unset variables that are actually
# referenced in the layer being applied — defining extras is harmless.
export TF_VAR_tenant_id="${KEYSTONE_TENANT_ID:-}"
export TF_VAR_mgmt_subscription_id="${KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID:-}"
export TF_VAR_connectivity_subscription_id="${KEYSTONE_PLATFORM_CONNECTIVITY_SUBSCRIPTION_ID:-}"
export TF_VAR_vending_subscription_id="${KEYSTONE_VENDING_CONTEXT_SUBSCRIPTION_ID:-}"
export TF_VAR_billing_scope_id="${KEYSTONE_MCA_BILLING_SCOPE_ID:-}"
export TF_VAR_budget_alert_email="${KEYSTONE_BUDGET_ALERT_EMAIL:-}"

# State storage account name: prefer the env var, fall back to az lookup.
# The az lookup is the documented post-vend behavior (operator may not
# have populated KEYSTONE_STATE_STORAGE_ACCOUNT_NAME yet).
if [[ -z "${KEYSTONE_STATE_STORAGE_ACCOUNT_NAME:-}" ]]; then
  export TF_VAR_state_storage_account_name="$(
    az storage account list \
      -g rg-tfstate-plat-weu-001 \
      --subscription "$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID" \
      --query "[0].name" -o tsv 2>/dev/null
  )"
else
  export TF_VAR_state_storage_account_name="$KEYSTONE_STATE_STORAGE_ACCOUNT_NAME"
fi

if [[ -z "${TF_VAR_state_storage_account_name:-}" ]]; then
  echo "ERROR: could not resolve state SA name. Has 00-bootstrap been applied?" >&2
  exit 2
fi

# --- Run terraform in the layer dir with the correct backend-config --------

cd "$layer_dir"

# Init quietly — the user usually doesn't care to see provider download lines.
# Failures still print because terraform writes errors to stderr.
terraform init -reconfigure \
  -backend-config="subscription_id=$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID" \
  -backend-config="tenant_id=$KEYSTONE_TENANT_ID" \
  -backend-config="resource_group_name=rg-tfstate-plat-weu-001" \
  -backend-config="storage_account_name=$TF_VAR_state_storage_account_name" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=platform-${layer}.tfstate" \
  > /dev/null

# Hand the rest off to terraform. Any args the caller passed after the
# subcommand (-var, -target, -auto-approve, etc.) flow through.
exec terraform "$cmd" "$@"
