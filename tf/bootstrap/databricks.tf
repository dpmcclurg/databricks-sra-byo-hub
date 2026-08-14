# Optional: grant each workspace UAMI the Unity Catalog privileges the spoke catalog module needs (create the storage
# credential, external location, and catalog), so the spoke layer can run AS the workspace UAMI instead of as a
# metastore admin. Without this, the spoke apply fails with "does not have CREATE EXTERNAL LOCATION on Metastore".
#
# This is dormant unless var.databricks_metastore_grant is set. It is separate from the Azure RBAC grants in rbac.tf
# because it is a Databricks-plane grant, and it needs a workspace already attached to the metastore - the metastore
# grants API is workspace-scoped even for a metastore-level securable, so there is nothing to target on a greenfield
# bootstrap run. Set the variable once the metastore and at least one workspace exist; a metastore admin runs the apply.

locals {
  databricks_metastore_grant_enabled = var.databricks_metastore_grant != null
}

# Account host provider, reaching Unity Catalog through an existing workspace. Uses the same OIDC/az-login auth as the
# azurerm provider (ARM_* env vars in CI, your az login locally). Configured unconditionally - it is only contacted by
# the grant resource below, which is count-guarded - so a run with the variable unset never calls Databricks.
provider "databricks" {
  host       = "https://accounts.azuredatabricks.net"
  account_id = try(var.databricks_metastore_grant.account_id, "")
}

# databricks_grant (singular) manages only THIS principal's privileges on the securable additively - unlike the plural
# databricks_grants, which is authoritative for the whole securable and would clobber the metastore owner's grants and
# everyone else's. One grant per workspace UAMI (keyed by environment).
resource "databricks_grant" "workspace_uami_metastore" {
  for_each = local.databricks_metastore_grant_enabled ? var.environments : {}

  metastore = var.databricks_metastore_grant.metastore_id

  # The UC principal for an Azure service principal is its application (client) ID.
  principal  = azurerm_user_assigned_identity.workspace[each.key].client_id
  privileges = var.databricks_metastore_grant.privileges

  # The metastore-grants API is workspace-scoped; point the account provider at a workspace attached to the metastore.
  provider_config {
    workspace_id = var.databricks_metastore_grant.workspace_id
  }
}
