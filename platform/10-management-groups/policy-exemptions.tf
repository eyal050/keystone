# Policy exemptions.
#
# Per CLAUDE.md §2: "Policy exemptions and deny-assignments — exercise
# both at least once, because interviewers ask about them."
#
# An exemption applies to a SCOPE for a specific ASSIGNMENT. It does
# NOT modify the policy definition or the assignment itself — the
# assignment continues to evaluate everywhere else in its inheritance
# tree. Exemptions are the right tool when you want most-of-the-tree
# to enforce a policy but a specific MG / sub / RG needs to be opted
# out for a documented reason.
#
# Two exemption categories exist:
#   - Waiver:    no compliance gap acknowledged; the scope is simply
#                opted out (e.g., "sandbox is permissive by design").
#   - Mitigated: there IS a compliance gap, but it is being mitigated
#                outside policy enforcement (e.g., "this sub is
#                inside a private network, the policy's threat model
#                doesn't apply").
#
# Best practice: every exemption documents its rationale via the
# `description` field. An exemption without a written-down reason is
# a red flag in audits.

# ---------------------------------------------------------------------------
# Exemption: keystone-sandbox MG is exempt from Environment-tag enum
#
# Sandbox is the lab's "break things on purpose" archetype — strict
# tag enforcement defeats its purpose. New MGs / subs in sandbox can
# be tagged with anything (including no Environment tag at all).
# ---------------------------------------------------------------------------

resource "azurerm_management_group_policy_exemption" "sandbox_environment_tag_waiver" {
  name                 = "sandbox-env-tag-waiver"
  display_name         = "Sandbox: exempt from Environment-tag enum enforcement"
  description          = "keystone-sandbox is the lab's experimentation archetype (CLAUDE.md §2). Strict Deny on the Environment-tag enum would block ad-hoc deploys, defeating sandbox's purpose. Resources here may use any Environment tag value, including none."
  exemption_category   = "Waiver"
  management_group_id  = azurerm_management_group.sandbox.id
  policy_assignment_id = azurerm_management_group_policy_assignment.environment_tag_enum.id
}
