# Subscription definitions for the for_each pattern in main.tf.
#
# Phase-1 = subs vended now, within current MCA quota (1 of 5 slots).
# Phase-2 = subs vended after the MCA quota increase support ticket is
# approved (see ADR-0009). They are merged into the for_each map only
# when var.vend_phase == "phase-2".

locals {
  phase_1_subs = {
    "platform-management" = {
      subscription_name = "keystone-platform-management"
      # The platform management plane (Log Analytics, diagnostic settings,
      # cost exports, Terraform state SA) is operationally Production —
      # losing it breaks every downstream layer's ability to deploy.
      workload = "Production"
    }
  }

  phase_2_subs = {
    "platform-connectivity" = {
      subscription_name = "keystone-platform-connectivity"
      workload          = "Production"
    }
    "platform-identity" = {
      subscription_name = "keystone-platform-identity"
      workload          = "Production"
    }
    "reelhouse-dev" = {
      subscription_name = "keystone-reelhouse-dev"
      # DevTest workload — eligible for any MCA dev-test pricing benefits
      # and clearly differentiates from prod in cost reports.
      workload = "DevTest"
    }
    "reelhouse-prod" = {
      subscription_name = "keystone-reelhouse-prod"
      workload          = "Production"
    }
  }

  subs_to_vend = var.vend_phase == "phase-2" ? merge(local.phase_1_subs, local.phase_2_subs) : local.phase_1_subs
}
