# Vault authorization.
#
# The vault uses Azure RBAC (rbac_authorization_enabled) rather than access policies. Access policies are vault-wide and
# accumulate one entry per identity, which does not suit a vault shared by N workspaces from N Terraform states. RBAC
# also lets the grant be delegated with Key Vault Data Access Administrator, so a spoke can grant wrap/unwrap to the
# identities it creates without holding broader rights on the vault.
#
# Role assignments are scoped to the *vault*, not to individual keys. Per the Key Vault RBAC guide, "Assigning roles on
# individual keys, secrets and certificates is not recommended", and its FAQ answers whether object-scope assignments
# isolate application teams with a flat "No" - any administrative operation still needs vault-level permission. With one
# shared key set serving every spoke, key-scoped assignments would add operational surface while isolating nothing.

# Object ID of the AzureDatabricks enterprise application (appId 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d), which unwraps
# the managed services key on the workspace's behalf.
#
# Note the provider's map key is "AzureDataBricks", with a capital B.
data "azuread_application_published_app_ids" "well_known" {
  count = var.databricks_service_principal_object_id == null ? 1 : 0
}

data "azuread_service_principal" "databricks" {
  count     = var.databricks_service_principal_object_id == null ? 1 : 0
  client_id = data.azuread_application_published_app_ids.well_known[0].result["AzureDataBricks"]
}

locals {
  # The override exists so the mock tests can plan without a live Microsoft Graph call. Left null in real deployments.
  databricks_sp_object_id = coalesce(
    var.databricks_service_principal_object_id,
    one(data.azuread_service_principal.databricks[*].object_id),
  )

  cmk_role_definition_name = "Key Vault Crypto Service Encryption User"
}

# The Databricks control plane unwraps the managed services key. This grant is made here, in the platform layer, rather
# than per spoke: it is one assignment for the whole vault regardless of how many workspaces use it, and making it early
# means it has propagated long before any spoke applies.
#
# The workspace-side grants - the workspace storage identity and the Disk Encryption Set identity - are made by the spoke
# that owns those identities, since they do not exist until the workspace is created. See modules/workspace.
resource "azurerm_role_assignment" "databricks_cmk" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = local.cmk_role_definition_name
  principal_id         = local.databricks_sp_object_id

  # Skips a Microsoft Graph lookup that is itself eventually consistent
  principal_type = "ServicePrincipal"

  description = "Granted by this Terraform configuration so the Azure Databricks control plane can wrap/unwrap the managed services CMK."
}
