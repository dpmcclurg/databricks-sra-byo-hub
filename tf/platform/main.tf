# Platform layer: the shared Key Vault and customer-managed keys for the Azure Databricks workspaces in one subscription
# and one region.
#
# This is applied ONCE per subscription per region, and it deliberately holds no Databricks resources and no workspace
# resources - there is no databricks provider here at all. Spoke workspaces are deployed from the configuration in tf/,
# once per workspace, each with its own state. They consume this layer's outputs as inputs.
#
# The split exists because the vault's lifecycle is not the workspace's lifecycle. A vault shared by N workspaces cannot
# live in a resource group that any one workspace's destroy would delete, and the identities that need wrap/unwrap on the
# keys do not exist until each workspace has been created. So: this layer owns the vault, the keys, and the control-plane
# grant; each spoke grants its own workspace identities.
#
# Region is a hard constraint, not a preference. Azure Databricks requires the vault to be in the same region and tenant
# as every workspace it serves, so if PROD spans regions it needs one instance of this configuration per region.
locals {
  # Tag names are lowercased before use. ARM lowercases tag names on some resource types - Microsoft.KeyVault/vaults/keys
  # is one - so a tag supplied as "Owner" is stored as "owner" there but kept as "Owner" elsewhere. Normalising here
  # means config matches what Azure stores on every resource type, instead of planning a change that can never converge.
  #
  # This is not cosmetic. Without it, a tag diff on the key resources makes their `output` unknown, which propagates to
  # the versioned key IDs read out of it, which makes every consuming workspace's CMK attributes "known after apply" -
  # pushing the workspace into the "Updating" state that its private endpoints race against, on every single apply.
  #
  # Kept identical to the same local in tf/main.tf. Do not let the two drift.
  tags = { for name, value in var.tags : lower(name) => value }

  resource_group_name = var.create_security_resource_group ? azurerm_resource_group.security[0].name : var.existing_security_resource_group_name
}

# Resource group for the platform's security assets: the vault and its keys. Separate from every workspace resource
# group so that destroying a workspace cannot take the shared vault with it.
resource "azurerm_resource_group" "security" {
  count = var.create_security_resource_group ? 1 : 0

  location = var.location
  name     = coalesce(var.security_resource_group_name, "rg-${var.resource_suffix}-security")
  tags     = local.tags
}

module "vault" {
  source = "./modules/keyvault"

  resource_suffix     = var.resource_suffix
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = local.tags

  tenant_id = data.azurerm_client_config.current.tenant_id

  key_vault_name             = var.key_vault_name
  key_name_prefix            = var.key_name_prefix
  soft_delete_retention_days = var.soft_delete_retention_days

  databricks_service_principal_object_id = var.databricks_service_principal_object_id
}
