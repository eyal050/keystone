# Terraform CI/CD — workload-dev vertical slice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `terraform plan`-on-PR and gated `terraform apply`-on-merge for `workloads/reelhouse/dev`, authenticated via two least-privilege OIDC-federated managed identities (read-only plan, read-write apply), with the apply identity's RBAC-admin grant constrained by an ABAC condition.

**Architecture:** Two new UAMIs + federated credentials live in the dev layer itself (`cicd.tf`); first apply is local (chicken-and-egg). Plan runs on PRs as a Reader identity; apply runs on merge as a Contributor + constrained-RBAC-admin identity gated behind the `workload-dev` GitHub Environment, whose required-reviewer approval is what lets GitHub mint the environment-scoped OIDC token. Cross-sub reach (state SA in management sub; hub peering/DNS in connectivity sub) is handled with provider aliases and narrow scoped grants, per ADR-0013.

**Tech Stack:** Terraform (`azurerm ~> 4.16`), Azure UAMI + federated identity credentials + ABAC role-assignment conditions, GitHub Actions, `azure/login@v2` OIDC, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-05-29-cicd-workload-dev-design.md`

**Branch:** `cicd-workload-dev` (already created; spec already committed there).

---

## Reference values used throughout

**Built-in Azure role definition GUIDs** (public, identical in every tenant — not secrets; source: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles):

| Role | GUID |
|---|---|
| AcrPull | `7f951dda-4ed3-4680-a7ca-43fe172d538d` |
| AcrPush | `8311e382-0749-4cb8-b61a-304f252e45ec` |
| Contributor | `b24988ac-6180-42a0-ab88-20f7382dd24c` |
| Key Vault Secrets User | `4633458b-17de-408a-b874-0445c86b69e6` |
| Storage Blob Data Contributor | `ba92f5b4-2d11-453d-a403-e96b0029c9fe` |

**Resource references in the dev layer (already exist):**
- `azurerm_resource_group.workload` — workload-sub RG (`rg-reelhouse-dev-workload-weu-001`)
- `azurerm_resource_group.network` — workload-sub network RG
- `data.terraform_remote_state.connectivity.outputs.hub_resource_group_name` — hub RG name (connectivity sub)
- Provider aliases: default (workload sub), `azurerm.connectivity` (existing). This plan adds `azurerm.management`.
- Vars (existing, no defaults): `var.tenant_id`, `var.workload_subscription_id`, `var.connectivity_subscription_id`, `var.mgmt_subscription_id`, `var.state_storage_account_name`, `var.operator_ip`. With defaults: `var.location_short` (`weu`), `var.required_tags`.

**Local run command (Claude, secrets sourced from `~/.keystone/secrets.env`):**
`./scripts/_tf-cmd.sh workloads/reelhouse/dev <subcommand> [args]`

---

## Task 1: Add the `management` provider alias

**Files:**
- Modify: `workloads/reelhouse/dev/providers.tf`

- [ ] **Step 1: Add the management alias**

Append to `workloads/reelhouse/dev/providers.tf`:

```hcl
# Aliased provider — management sub. Used SOLELY to assign the two CI
# identities Storage Blob Data roles on the Terraform state container,
# which lives in the management sub (rg-tfstate-plat-weu-001) per ADR-0007.
provider "azurerm" {
  alias           = "management"
  subscription_id = var.mgmt_subscription_id
  tenant_id       = var.tenant_id

  features {}
}
```

- [ ] **Step 2: fmt + validate**

Run: `terraform -chdir=workloads/reelhouse/dev fmt` then `./scripts/_tf-cmd.sh workloads/reelhouse/dev validate`
Expected: `fmt` reports the file (or nothing), `validate` prints `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add workloads/reelhouse/dev/providers.tf
git commit -m "workloads/reelhouse/dev: add management provider alias for CI state grants"
```

---

## Task 2: CI identities + federated credentials

**Files:**
- Create: `workloads/reelhouse/dev/cicd.tf`

- [ ] **Step 1: Create `cicd.tf` with the two UAMIs and their federated credentials**

```hcl
# Terraform CI/CD identities for workloads/reelhouse/dev.
#
# Two OIDC-federated user-assigned managed identities run this layer in
# GitHub Actions (CLAUDE.md §5, design spec 2026-05-29):
#
#   - tfplan  (read-only)  — runs `terraform plan` on pull_request
#   - tfapply (read-write) — runs `terraform apply` on push-to-main,
#                            gated behind the `workload-dev` GitHub
#                            Environment.
#
# CHICKEN-AND-EGG: CI cannot create the identity it authenticates as,
# so the FIRST apply of this file is run locally by the operator (same
# pattern as platform/00-bootstrap). Thereafter CI owns the layer.
#
# These identities' OWN role assignments are deliberately NOT in the
# tfapply ABAC allow-list (see locals.rbac_admin_condition) — CI must
# not be able to modify its own privileges. They stay operator/local-
# apply-owned, exactly like operator_kv_admin in keyvault.tf.

# --- Plan identity (read-only) ---------------------------------------------

resource "azurerm_user_assigned_identity" "tfplan" {
  name                = "uami-tfplan-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  tags = var.required_tags
}

# Federated to PRs: subject `repo:eyal050/keystone:pull_request`. Any PR
# in the repo can mint this identity's token to run plan — read-only, so
# safe by construction.
resource "azurerm_federated_identity_credential" "tfplan_pr" {
  name                = "github-pull-request"
  resource_group_name = azurerm_resource_group.workload.name
  parent_id           = azurerm_user_assigned_identity.tfplan.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = "https://token.actions.githubusercontent.com"
  subject  = "repo:eyal050/keystone:pull_request"
}

# --- Apply identity (read-write) -------------------------------------------

resource "azurerm_user_assigned_identity" "tfapply" {
  name                = "uami-tfapply-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  tags = var.required_tags
}

# Federated to the `workload-dev` ENVIRONMENT, not a branch. GitHub only
# issues a token with subject `...:environment:workload-dev` AFTER the
# environment's required-reviewer approval passes — so this credential is
# cryptographically unobtainable without the human gate.
resource "azurerm_federated_identity_credential" "tfapply_env" {
  name                = "github-env-workload-dev"
  resource_group_name = azurerm_resource_group.workload.name
  parent_id           = azurerm_user_assigned_identity.tfapply.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = "https://token.actions.githubusercontent.com"
  subject  = "repo:eyal050/keystone:environment:workload-dev"
}
```

- [ ] **Step 2: fmt + validate**

Run: `terraform -chdir=workloads/reelhouse/dev fmt` then `./scripts/_tf-cmd.sh workloads/reelhouse/dev validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add workloads/reelhouse/dev/cicd.tf
git commit -m "workloads/reelhouse/dev: CI plan/apply UAMIs + federated creds"
```

---

## Task 3: Workload-sub role assignments + ABAC condition

**Files:**
- Modify: `workloads/reelhouse/dev/cicd.tf`

- [ ] **Step 1: Add a `locals` block with the ABAC condition**

Append to `cicd.tf`. The condition allows `roleAssignments/write` and `/delete`
only for the five app-plane role GUIDs (write checks `@Request`, delete checks
`@Resource` — Microsoft's documented pattern):

```hcl
locals {
  # App-plane roles the layer grants to application principals (app-deploy
  # UAMI + ACA managed identity). The tfapply identity may write/delete role
  # assignments ONLY for these. RBAC-admin / Owner / Key Vault Administrator
  # are intentionally absent → no privilege escalation, and CI cannot touch
  # operator grants or its own grants.
  cicd_allowed_role_guids = [
    "7f951dda-4ed3-4680-a7ca-43fe172d538d", # AcrPull
    "8311e382-0749-4cb8-b61a-304f252e45ec", # AcrPush
    "b24988ac-6180-42a0-ab88-20f7382dd24c", # Contributor
    "4633458b-17de-408a-b874-0445c86b69e6", # Key Vault Secrets User
    "ba92f5b4-2d11-453d-a403-e96b0029c9fe", # Storage Blob Data Contributor
  ]

  cicd_role_guids_csv = join(", ", local.cicd_allowed_role_guids)

  rbac_admin_condition = <<-COND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.cicd_role_guids_csv}}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.cicd_role_guids_csv}}
     )
    )
  COND
}
```

- [ ] **Step 2: Add the workload-sub role assignments**

Append to `cicd.tf`:

```hcl
# --- Plan identity: Reader on both workload-sub RGs ------------------------

resource "azurerm_role_assignment" "tfplan_workload_reader" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.tfplan.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "tfplan_network_reader" {
  scope                = azurerm_resource_group.network.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.tfplan.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Apply identity: Contributor on both workload-sub RGs ------------------

resource "azurerm_role_assignment" "tfapply_workload_contributor" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "tfapply_network_contributor" {
  scope                = azurerm_resource_group.network.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Apply identity: constrained RBAC-admin on the workload RG -------------
# Contributor excludes Microsoft.Authorization/roleAssignments/write, so the
# apply identity needs RBAC-admin to create the layer's role assignments. The
# ABAC condition restricts it to the five app-plane roles only.
resource "azurerm_role_assignment" "tfapply_rbac_admin" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"

  condition_version = "2.0"
  condition         = local.rbac_admin_condition
}
```

- [ ] **Step 3: fmt + validate**

Run: `terraform -chdir=workloads/reelhouse/dev fmt` then `./scripts/_tf-cmd.sh workloads/reelhouse/dev validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add workloads/reelhouse/dev/cicd.tf
git commit -m "workloads/reelhouse/dev: CI workload-sub RBAC + constrained RBAC-admin (ABAC)"
```

---

## Task 4: Cross-sub grants (connectivity hub RG + state container)

**Files:**
- Modify: `workloads/reelhouse/dev/cicd.tf`

- [ ] **Step 1: Add data sources for the hub RG and the state SA**

Append to `cicd.tf`:

```hcl
# Hub RG (connectivity sub) — scope for the narrow connectivity grant. Name
# comes from 30-connectivity's remote state; resolve its ID via the
# connectivity-aliased provider.
data "azurerm_resource_group" "hub" {
  provider = azurerm.connectivity
  name     = data.terraform_remote_state.connectivity.outputs.hub_resource_group_name
}

# State SA (management sub) — scope for the state-container grants.
data "azurerm_storage_account" "state" {
  provider            = azurerm.management
  name                = var.state_storage_account_name
  resource_group_name = "rg-tfstate-plat-weu-001"
}

locals {
  # ARM ID of the state blob container the azurerm backend uses.
  state_container_id = "${data.azurerm_storage_account.state.id}/blobServices/default/containers/tfstate"
}
```

- [ ] **Step 2: Add the connectivity-sub grants (ADR-0013 "both-sub identity")**

Append to `cicd.tf`. Network Contributor covers the hub-side peering; Private
DNS Zone Contributor covers the spoke's DNS zone link — both scoped to the hub
RG only:

```hcl
# --- Plan identity: Reader on the hub RG (connectivity sub) ----------------

resource "azurerm_role_assignment" "tfplan_hub_reader" {
  provider             = azurerm.connectivity
  scope                = data.azurerm_resource_group.hub.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.tfplan.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Apply identity: narrow connectivity grants (hub RG only) --------------

resource "azurerm_role_assignment" "tfapply_hub_network" {
  provider             = azurerm.connectivity
  scope                = data.azurerm_resource_group.hub.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "tfapply_hub_dns" {
  provider             = azurerm.connectivity
  scope                = data.azurerm_resource_group.hub.id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"
}
```

- [ ] **Step 3: Add the state-container grants (management sub)**

Append to `cicd.tf`:

```hcl
# --- State container access (management sub, via use_azuread_auth) ---------

resource "azurerm_role_assignment" "tfplan_state_reader" {
  provider             = azurerm.management
  scope                = local.state_container_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.tfplan.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "tfapply_state_contributor" {
  provider             = azurerm.management
  scope                = local.state_container_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"
}
```

- [ ] **Step 4: fmt + validate**

Run: `terraform -chdir=workloads/reelhouse/dev fmt` then `./scripts/_tf-cmd.sh workloads/reelhouse/dev validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add workloads/reelhouse/dev/cicd.tf
git commit -m "workloads/reelhouse/dev: CI cross-sub grants (hub RG + state container)"
```

---

## Task 5: Outputs for the CI client IDs

**Files:**
- Modify: `workloads/reelhouse/dev/outputs.tf`

- [ ] **Step 1: Append the two client-ID outputs**

```hcl
output "tfplan_client_id" {
  description = "Client ID of the read-only Terraform plan identity. Set as repo secret AZURE_TF_PLAN_CLIENT_ID."
  value       = azurerm_user_assigned_identity.tfplan.client_id
  sensitive   = true
}

output "tfapply_client_id" {
  description = "Client ID of the read-write Terraform apply identity. Set as workload-dev environment secret AZURE_TF_APPLY_CLIENT_ID."
  value       = azurerm_user_assigned_identity.tfapply.client_id
  sensitive   = true
}
```

- [ ] **Step 2: fmt + validate**

Run: `terraform -chdir=workloads/reelhouse/dev fmt` then `./scripts/_tf-cmd.sh workloads/reelhouse/dev validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add workloads/reelhouse/dev/outputs.tf
git commit -m "workloads/reelhouse/dev: outputs for CI plan/apply client IDs"
```

---

## Task 6: First local apply (chicken-and-egg) + set GitHub secrets

This task is executed locally by Claude with `~/.keystone/secrets.env` sourced.
No new code; it bootstraps the identities CI will use.

- [ ] **Step 1: Plan locally and review**

Run: `./scripts/_tf-cmd.sh workloads/reelhouse/dev plan`
Expected: plan shows **only additions** — 2 UAMIs, 2 federated credentials, 8
role assignments, 2 data sources read. Zero changes/destroys to existing
resources. If anything else appears, STOP and investigate before applying.

- [ ] **Step 2: Apply locally**

Run: `./scripts/_tf-cmd.sh workloads/reelhouse/dev apply`
Type `yes` at the prompt (do NOT use `-auto-approve` for this bootstrap).
Expected: `Apply complete!` with the new resources created.

- [ ] **Step 3: Set the two client-ID secrets (values never printed)**

```bash
cd workloads/reelhouse/dev
terraform output -raw tfplan_client_id  | gh secret set AZURE_TF_PLAN_CLIENT_ID
terraform output -raw tfapply_client_id | gh secret set AZURE_TF_APPLY_CLIENT_ID --env workload-dev
cd -
```

> NOTE: `--env workload-dev` requires the environment to exist (Task 7). If
> `gh` errors that the environment is missing, run Task 7 first, then this line.

- [ ] **Step 4: Set the remaining TF_VAR secrets from the local secrets file**

These are sourced from `~/.keystone/secrets.env` and piped into `gh` without
echoing. Run each (adjust the source var name if the local file differs):

```bash
source ~/.keystone/secrets.env
printf '%s' "$KEYSTONE_PLATFORM_CONNECTIVITY_SUBSCRIPTION_ID" | gh secret set AZURE_CONNECTIVITY_SUBSCRIPTION_ID
printf '%s' "$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID"   | gh secret set AZURE_MGMT_SUBSCRIPTION_ID
printf '%s' "$KEYSTONE_OPERATOR_IP"                            | gh secret set OPERATOR_IP
```

> If `KEYSTONE_OPERATOR_IP` is not the exact var name in `~/.keystone/secrets.env`,
> check the file's variable names first (`grep -i operator ~/.keystone/secrets.env`)
> and use the correct one. Do not hardcode the IP.

- [ ] **Step 5: Confirm the secret set (names only, no values)**

Run: `gh secret list` and `gh secret list --env workload-dev`
Expected: repo list contains `AZURE_TF_PLAN_CLIENT_ID`, `AZURE_CONNECTIVITY_SUBSCRIPTION_ID`,
`AZURE_MGMT_SUBSCRIPTION_ID`, `OPERATOR_IP`, plus pre-existing `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`. Environment list contains `AZURE_TF_APPLY_CLIENT_ID`.

---

## Task 7: Create the `workload-dev` GitHub Environment with a required reviewer

- [ ] **Step 1: Create the environment with Eyal as required reviewer**

GitHub's REST API creates the environment and sets protection in one call. Get
the numeric user ID first, then create:

```bash
OWNER_ID=$(gh api /users/eyal050 --jq .id)
gh api --method PUT "/repos/eyal050/keystone/environments/workload-dev" \
  -f "wait_timer=0" \
  -F "reviewers[][type]=User" \
  -F "reviewers[][id]=${OWNER_ID}"
```

Expected: JSON response with `"name": "workload-dev"` and a
`protection_rules` array containing a `required_reviewers` rule.

- [ ] **Step 2: Verify the gate**

Run: `gh api "/repos/eyal050/keystone/environments/workload-dev" --jq '.protection_rules[].type'`
Expected: output includes `required_reviewers`.

> If Task 6 Step 3's `--env workload-dev` secret was deferred, set it now.

---

## Task 8: Plan workflow

**Files:**
- Create: `.github/workflows/reelhouse-dev-plan.yml`

- [ ] **Step 1: Create the plan workflow**

```yaml
name: reelhouse-dev-plan

# Terraform plan for workloads/reelhouse/dev on PRs. Read-only: authenticates
# as the tfplan UAMI (Reader) via federated OIDC. Posts the plan as a PR
# comment. No apply, no state lock (-lock=false). Design spec 2026-05-29.

on:
  pull_request:
    paths:
      - "workloads/reelhouse/dev/**"
      - ".github/workflows/reelhouse-dev-plan.yml"

permissions:
  id-token: write       # OIDC token exchange
  contents: read        # checkout
  pull-requests: write  # post plan comment

env:
  TF_VERSION: "1.9.8"
  LAYER_DIR: workloads/reelhouse/dev
  STATE_RG: rg-tfstate-plat-weu-001
  STATE_CONTAINER: tfstate
  STATE_KEY: workloads-reelhouse-dev.tfstate
  ARM_USE_AZUREAD: "true"
  # Non-sensitive TF_VARs (match terraform.tfvars defaults; sensitive ones
  # come from secrets below).
  TF_VAR_tenant_id: ${{ secrets.AZURE_TENANT_ID }}
  TF_VAR_workload_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  TF_VAR_connectivity_subscription_id: ${{ secrets.AZURE_CONNECTIVITY_SUBSCRIPTION_ID }}
  TF_VAR_mgmt_subscription_id: ${{ secrets.AZURE_MGMT_SUBSCRIPTION_ID }}
  TF_VAR_operator_ip: ${{ secrets.OPERATOR_IP }}

jobs:
  plan:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    defaults:
      run:
        shell: bash
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Azure OIDC login (tfplan, read-only)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_TF_PLAN_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: State SA name into env
        run: echo "TF_VAR_state_storage_account_name=$STATE_SA" >> "$GITHUB_ENV"
        env:
          # State SA name is a public output, not a §6-forbidden value.
          STATE_SA: REPLACE_WITH_STATE_SA_NAME

      - name: terraform fmt -check
        run: terraform -chdir="$LAYER_DIR" fmt -check -recursive

      - name: Setup TFLint
        uses: terraform-linters/setup-tflint@v4

      - name: tflint
        run: |
          cd "$LAYER_DIR"
          tflint --init
          tflint

      - name: tfsec
        uses: aquasecurity/tfsec-action@v1.0.3
        with:
          working_directory: ${{ env.LAYER_DIR }}

      - name: terraform init
        run: |
          terraform -chdir="$LAYER_DIR" init \
            -backend-config="subscription_id=${{ secrets.AZURE_MGMT_SUBSCRIPTION_ID }}" \
            -backend-config="tenant_id=${{ secrets.AZURE_TENANT_ID }}" \
            -backend-config="resource_group_name=$STATE_RG" \
            -backend-config="storage_account_name=$TF_VAR_state_storage_account_name" \
            -backend-config="container_name=$STATE_CONTAINER" \
            -backend-config="key=$STATE_KEY" \
            -backend-config="use_azuread_auth=true"

      - name: terraform plan
        id: plan
        run: |
          terraform -chdir="$LAYER_DIR" plan -lock=false -no-color -input=false \
            | tee plan.txt

      - name: Post plan as PR comment
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('plan.txt', 'utf8');
            const body = [
              '#### `terraform plan` — workloads/reelhouse/dev',
              '```',
              plan.length > 60000 ? plan.slice(-60000) : plan,
              '```'
            ].join('\n');
            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body
            });
```

- [ ] **Step 2: Fill in the state SA name**

Replace `REPLACE_WITH_STATE_SA_NAME` with the actual state SA name (a public,
non-§6 resource name — safe to commit, same as `ACR_NAME` in the existing app
workflow). Read it from the local secrets file:

Run: `source ~/.keystone/secrets.env && echo "$KEYSTONE_STATE_STORAGE_ACCOUNT_NAME"`
Then edit the workflow's `STATE_SA:` value to that literal string.

Expected: `STATE_SA: <the real SA name>`, no longer `REPLACE_WITH_STATE_SA_NAME`.

- [ ] **Step 3: Validate the YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/reelhouse-dev-plan.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/reelhouse-dev-plan.yml
git commit -m "ci: reelhouse-dev-plan workflow (read-only tfplan OIDC, PR comment)"
```

---

## Task 9: Apply workflow

**Files:**
- Create: `.github/workflows/reelhouse-dev-apply.yml`

- [ ] **Step 1: Create the apply workflow**

```yaml
name: reelhouse-dev-apply

# Terraform apply for workloads/reelhouse/dev on merge to main. Gated behind
# the `workload-dev` GitHub Environment (required reviewer). Authenticates as
# the tfapply UAMI via federated OIDC — whose subject is environment-scoped,
# so the token is only mintable AFTER the environment approval. Design spec
# 2026-05-29.

on:
  push:
    branches: [main]
    paths:
      - "workloads/reelhouse/dev/**"
      - ".github/workflows/reelhouse-dev-apply.yml"
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

env:
  TF_VERSION: "1.9.8"
  LAYER_DIR: workloads/reelhouse/dev
  STATE_RG: rg-tfstate-plat-weu-001
  STATE_CONTAINER: tfstate
  STATE_KEY: workloads-reelhouse-dev.tfstate
  ARM_USE_AZUREAD: "true"
  TF_VAR_tenant_id: ${{ secrets.AZURE_TENANT_ID }}
  TF_VAR_workload_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  TF_VAR_connectivity_subscription_id: ${{ secrets.AZURE_CONNECTIVITY_SUBSCRIPTION_ID }}
  TF_VAR_mgmt_subscription_id: ${{ secrets.AZURE_MGMT_SUBSCRIPTION_ID }}
  TF_VAR_operator_ip: ${{ secrets.OPERATOR_IP }}

jobs:
  apply:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    environment: workload-dev   # <-- the approval gate
    defaults:
      run:
        shell: bash
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Azure OIDC login (tfapply, read-write)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_TF_APPLY_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: State SA name into env
        run: echo "TF_VAR_state_storage_account_name=$STATE_SA" >> "$GITHUB_ENV"
        env:
          STATE_SA: REPLACE_WITH_STATE_SA_NAME

      - name: terraform init
        run: |
          terraform -chdir="$LAYER_DIR" init \
            -backend-config="subscription_id=${{ secrets.AZURE_MGMT_SUBSCRIPTION_ID }}" \
            -backend-config="tenant_id=${{ secrets.AZURE_TENANT_ID }}" \
            -backend-config="resource_group_name=$STATE_RG" \
            -backend-config="storage_account_name=$TF_VAR_state_storage_account_name" \
            -backend-config="container_name=$STATE_CONTAINER" \
            -backend-config="key=$STATE_KEY" \
            -backend-config="use_azuread_auth=true"

      - name: terraform apply
        run: |
          terraform -chdir="$LAYER_DIR" apply -input=false -auto-approve -no-color
```

- [ ] **Step 2: Fill in the state SA name**

Replace `REPLACE_WITH_STATE_SA_NAME` with the same literal value used in Task 8 Step 2.

- [ ] **Step 3: Validate the YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/reelhouse-dev-apply.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/reelhouse-dev-apply.yml
git commit -m "ci: reelhouse-dev-apply workflow (env-gated tfapply OIDC)"
```

---

## Task 10: ADR + break-debug log + spec status

**Files:**
- Create: `docs/decisions/0018-terraform-ci-workload-dev.md`
- Modify: `docs/break-debug-log.md`
- Modify: `docs/superpowers/specs/2026-05-29-cicd-workload-dev-design.md` (status line)

- [ ] **Step 1: Write ADR-0018**

Create `docs/decisions/0018-terraform-ci-workload-dev.md` capturing the four
resolved decisions (matching the existing ADR format in the directory):

```markdown
# ADR-0018: Terraform CI/CD for workloads/reelhouse/dev

- **Status**: Accepted
- **Date**: 2026-05-29
- **Decider**: Eyal
- **Builds on**: CLAUDE.md §5, ADR-0007 (state in management sub),
  ADR-0013 (workload owns the spoke network seam; CI = both-sub federated
  identity), ADR-0015 (app build/deploy OIDC pattern)

## Context

Every Terraform apply was a local laptop run. CLAUDE.md §5 prescribes
plan-on-PR / apply-on-merge with OIDC and an environment approval gate.
This ADR records the first vertical slice: Terraform CI for the
workloads/reelhouse/dev layer only. Full design:
docs/superpowers/specs/2026-05-29-cicd-workload-dev-design.md.

## Decisions

1. **First slice = workloads/reelhouse/dev.** Highest churn, lowest blast
   radius, already carries OIDC plumbing (ADR-0015). Other environments
   and platform layers are deferred.
2. **Split identities.** A read-only `tfplan` UAMI runs plan on PRs; a
   read-write `tfapply` UAMI runs apply on merge. A malicious/buggy PR
   cannot mutate Azure because its OIDC subject only maps to Reader.
3. **Constrained RBAC-admin.** `Contributor` cannot write role assignments,
   so `tfapply` also holds `Role Based Access Control Administrator` —
   constrained by an ABAC condition to the five app-plane role GUIDs
   (AcrPull, AcrPush, Contributor, Key Vault Secrets User, Storage Blob
   Data Contributor). RBAC-admin / Owner / Key Vault Administrator are NOT
   allow-listed → no privilege escalation, and CI cannot modify operator
   grants or its own grants.
4. **CI identities live in the layer; first apply is local.** Same
   chicken-and-egg as 00-bootstrap. Documented in the spec.

## Cross-sub handling (per ADR-0013)

The layer writes to three scopes: workload + network RGs (workload sub) and
the hub RG (connectivity sub, via the connectivity provider alias, for
hub-side peering + DNS link). `tfapply` gets narrow `Network Contributor` +
`Private DNS Zone Contributor` scoped to the hub RG only — the least-priv
expression of the "both-sub federated identity" ADR-0013 pre-planned.
Re-homing those resources to a platform layer was considered and rejected:
it reverses ADR-0013 and reintroduces the dependency inversion that ADR
avoids.

## Gate is cryptographic

`tfapply`'s federated subject is `...:environment:workload-dev`, so GitHub
only mints its token after the environment's required-reviewer approval.
The approval is not merely procedural — without it the apply credential is
unobtainable.

## Consequences

- Local applies still work (the wrapper is unchanged); CI is additive.
- Fan-out to other environments / platform layers is a later session and
  may centralize CI-identity vending and relocate the state-container
  grants to the management layer.
```

- [ ] **Step 2: Add a break-debug-log note for the session**

Append to `docs/break-debug-log.md`:

```markdown
## 2026-05-29 — Terraform CI slice (no break/debug practiced)

No failure was injected this session — the work was building the
workload-dev Terraform CI slice (ADR-0018). Two latent break/debug seeds
were created for later:

- **Constrained-RBAC-admin 403**: if a future PR adds a role assignment
  whose role is NOT in the ABAC allow-list (e.g. grants Key Vault
  Administrator, or a new role), CI apply 403s on exactly that resource
  with `RoleAssignmentUpdateNotPermitted` / authorization failure. The
  signal to look at first: the failing resource address in the apply log
  names the role; cross-reference local.cicd_allowed_role_guids in cicd.tf.
- **Plan identity cannot apply (asserted, not tested)**: the tfplan UAMI is
  Reader-only; an apply with it returns 403. Documents the least-priv
  boundary.
```

- [ ] **Step 3: Flip the spec status line to implemented**

In `docs/superpowers/specs/2026-05-29-cicd-workload-dev-design.md`, change:
`- **Status**: Approved (brainstorming), pending implementation plan`
to:
`- **Status**: Implemented (see ADR-0018)`

- [ ] **Step 4: Commit**

```bash
git add docs/decisions/0018-terraform-ci-workload-dev.md docs/break-debug-log.md docs/superpowers/specs/2026-05-29-cicd-workload-dev-design.md
git commit -m "docs: ADR-0018 + break-debug seeds for workload-dev Terraform CI"
```

---

## Task 11: Live verification (the slice actually works)

Per CLAUDE.md "verify the actual outcome" — prove plan-on-PR and gated-apply
both function end-to-end, not just that files were written.

- [ ] **Step 1: Push the branch and open a PR**

```bash
git push -u origin cicd-workload-dev
gh pr create --fill --base main --head cicd-workload-dev
```

Expected: PR created. Because the branch touches `workloads/reelhouse/dev/**`
and the plan workflow file, `reelhouse-dev-plan` triggers.

- [ ] **Step 2: Confirm the plan workflow ran green and commented**

Run: `gh pr checks` (wait for completion) and `gh run list --workflow=reelhouse-dev-plan.yml --limit 1`
Expected: the `reelhouse-dev-plan` run concludes `success`; a `terraform plan`
comment is posted on the PR. If it fails on fmt/tflint/tfsec, fix and push.

> Most likely first-run failure: a missing `tflint`/`tfsec` finding, or the
> backend `use_azuread_auth` path. Read the failing step's log; the plan
> identity has Reader + Storage Blob Data Reader, which is sufficient for a
> `-lock=false` plan. A 403 reading state means the state grant (Task 4 Step 3)
> didn't apply — re-check Task 6.

- [ ] **Step 3: Merge and watch the apply gate**

```bash
gh pr merge --squash --auto
```

Expected: on merge to `main`, `reelhouse-dev-apply` starts then **pauses** for
environment approval (`gh run list --workflow=reelhouse-dev-apply.yml` shows it
waiting).

- [ ] **Step 4: Approve the environment and confirm idempotent apply**

Approve via the GitHub UI (Actions → the waiting run → Review deployments →
approve `workload-dev`), or:

```bash
RUN_ID=$(gh run list --workflow=reelhouse-dev-apply.yml --limit 1 --json databaseId --jq '.[0].databaseId')
# Approving deployment gates requires the UI or a PAT with deployment scope;
# if `gh` cannot approve, do it in the browser.
```

Expected: after approval, the apply runs and reports **no changes** (the layer
was already applied locally in Task 6) or only the expected drift. Run concludes
`success`.

- [ ] **Step 5: Final confirmation**

Run: `gh run list --workflow=reelhouse-dev-apply.yml --limit 1`
Expected: status `completed`, conclusion `success`. The slice is proven:
plan-on-PR (read-only) + gated apply-on-merge (env-scoped OIDC) both work.

---

## Self-review notes (addressed)

- **Spec coverage**: every spec section maps to a task — identities (T2),
  ABAC + buckets (T3), cross-sub grants (T4), outputs (T5), bootstrap + all
  secrets (T6), environment gate (T7), plan workflow + pre-merge checks (T8),
  apply workflow (T9), ADR + break-debug (T10), verification incl. asserted
  negative test (T11).
- **Placeholders**: the only intentional placeholders are `REPLACE_WITH_STATE_SA_NAME`
  (T8 S2, T9 S2) — explicitly resolved by a step, because the value is
  environment-specific and must not be guessed.
- **Type/name consistency**: resource names (`tfplan`/`tfapply`, role-assignment
  addresses, `local.rbac_admin_condition`, `local.state_container_id`) are used
  identically across T2–T5 and referenced by the same names in T11's failure
  hints.
