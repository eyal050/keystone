# MCA-vended Keystone subscriptions.
#
# A single resource block with for_each over local.subs_to_vend covers
# all five subs. Phasing is achieved by varying which keys appear in the
# map (locals.tf), not by varying the resource code between runs.
#
# prevent_destroy = true is non-negotiable per CLAUDE.md §7 — cancelled
# MCA subs count against quota for 90 days and burning the platform sub
# shells would cascade through every downstream layer. terraform destroy
# against this layer must fail by design.

resource "azurerm_subscription" "this" {
  for_each = local.subs_to_vend

  alias             = each.key
  subscription_name = each.value.subscription_name
  billing_scope_id  = var.billing_scope_id
  workload          = each.value.workload

  lifecycle {
    prevent_destroy = true

    # The billing scope is set once at vend time. Re-pointing a sub to
    # a different invoice section is non-trivial and would surprise
    # anyone reading the diff; require an explicit code change to do it.
    ignore_changes = [billing_scope_id]
  }
}
