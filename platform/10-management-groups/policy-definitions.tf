# Custom policy definitions. Built-in policies (allowed locations,
# require HTTPS on storage, etc.) are referenced by ID at assignment
# time — they exist in every Azure tenant by default and need no
# Terraform resource. This file is reserved for policies the project
# defines itself.
#
# CLAUDE.md §2 calls for "at least one custom policy definition, not
# just built-ins." That requirement is satisfied here.

# ---------------------------------------------------------------------------
# keystone-required-tag-enum
#
# Built-in "Require a tag and its value on resources"
# (1e30110a-5ceb-460c-a204-c1c3969c6d62) checks that a tag has ONE
# specific value. ADR-0008's tag taxonomy uses ENUM-restricted tags:
#   Environment        ∈ {platform, dev, prod, sandbox}
#   DataClassification ∈ {public, internal, confidential, restricted}
# Enforcing those with the built-in requires N separate assignments
# per tag (one per allowed value, joined as Audit), which is awkward.
#
# This custom policy parameterizes both the tag name and the list of
# allowed values, so a single definition supports every enum-tag in
# ADR-0008 with one assignment per tag (E3 will create those
# assignments). The effect is also parameterized so the policy can
# be assigned as Deny at keystone scope and Audit-only on the
# Sandbox MG.
# ---------------------------------------------------------------------------

resource "azurerm_policy_definition" "required_tag_enum" {
  name                = "keystone-required-tag-enum"
  display_name        = "Keystone — Tag value must be in the allowed enum"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.top.id

  metadata = jsonencode({
    category = "Keystone Tags"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    tagName = {
      type = "String"
      metadata = {
        displayName = "Tag name"
        description = "Name of the tag to enforce (e.g. Environment, DataClassification)."
      }
    }
    allowedValues = {
      type = "Array"
      metadata = {
        displayName = "Allowed values"
        description = "Allowed values for the named tag. Resources with a missing tag or a value not in this list violate the policy."
      }
    }
    effect = {
      type         = "String"
      defaultValue = "Deny"
      allowedValues = [
        "Deny",
        "Audit",
        "Disabled",
      ]
      metadata = {
        displayName = "Effect"
        description = "Policy effect. Deny blocks non-compliant resource create/update. Audit logs without blocking. Disabled turns the policy off (useful for staged rollouts)."
      }
    }
  })

  # The field reference uses an ARM template expression to construct
  # tags['<tagName>'] from the parameter. The doubled single-quotes
  # are ARM's escape syntax inside a string literal.
  policy_rule = jsonencode({
    if = {
      not = {
        field = "[concat('tags[''', parameters('tagName'), ''']')]"
        in    = "[parameters('allowedValues')]"
      }
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}
