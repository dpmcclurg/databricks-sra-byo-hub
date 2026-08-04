# Private connectivity for the workspace default storage account.
#
# Every Azure Databricks workspace has a default storage account in its managed resource group. It holds workspace
# system data, MLflow artifacts, query results, and the (deprecated) DBFS root. The account is mandatory and cannot be
# removed, so securing it is separate from whether DBFS itself is in use.
#
# When secure_workspace_default_storage is enabled, default_storage_firewall_enabled is set on the workspace and public
# access to this account is blocked. That requires:
#   - private endpoints for the dfs and blob sub-resources, so the injected VNet can reach it
#   - NCC private endpoints, so serverless compute can reach it
#   - an access connector (managed identity), so the control and serverless planes can authenticate
#
# The access connector is deliberately created in the spoke resource group rather than the workspace managed resource
# group: enabling the storage firewall can delete a connector that lives in the managed resource group, which would
# break any Unity Catalog external locations bound to it.
locals {
  default_storage_sa_resource_id = join("", [azurerm_databricks_workspace.this.managed_resource_group_id, "/providers/Microsoft.Storage/storageAccounts/", local.default_storage_name])
}

# Private endpoint for the default storage account's dfs sub-resource
resource "azurerm_private_endpoint" "default_storage_dfs" {
  count = var.secure_workspace_default_storage ? 1 : 0

  name                = "pe-default-storage-dfs"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.network_configuration.private_endpoint_subnet_id

  private_service_connection {
    name                           = "ple-${var.resource_suffix}-default-storage-dfs"
    private_connection_resource_id = local.default_storage_sa_resource_id
    is_manual_connection           = false
    subresource_names              = ["dfs"]
  }

  private_dns_zone_group {
    name                 = "private-dns-zone-default-storage-dfs"
    private_dns_zone_ids = [var.dns_zone_ids.dfs]
  }

  tags       = var.tags
  depends_on = [azurerm_databricks_workspace.this]
}

# Private endpoint for the default storage account's blob sub-resource
resource "azurerm_private_endpoint" "default_storage_blob" {
  count = var.secure_workspace_default_storage ? 1 : 0

  name                = "pe-default-storage-blob"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.network_configuration.private_endpoint_subnet_id

  private_service_connection {
    name                           = "ple-${var.resource_suffix}-default-storage-blob"
    private_connection_resource_id = local.default_storage_sa_resource_id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "private-dns-zone-default-storage-blob"
    private_dns_zone_ids = [var.dns_zone_ids.blob]
  }

  tags       = var.tags
  depends_on = [azurerm_databricks_workspace.this]
}

# NCC private endpoints so serverless compute can reach the default storage account
module "ncc_default_storage_blob" {
  source = "../self-approving-pe"
  count  = var.secure_workspace_default_storage ? 1 : 0

  databricks_account_id            = var.databricks_account_id
  group_id                         = "blob"
  network_connectivity_config_id   = var.ncc_id
  resource_id                      = local.default_storage_sa_resource_id
  network_connectivity_config_name = var.ncc_name
}

module "ncc_default_storage_dfs" {
  source = "../self-approving-pe"
  count  = var.secure_workspace_default_storage ? 1 : 0

  databricks_account_id            = var.databricks_account_id
  group_id                         = "dfs"
  network_connectivity_config_id   = var.ncc_id
  resource_id                      = local.default_storage_sa_resource_id
  network_connectivity_config_name = var.ncc_name
}

# Access connector the control and serverless planes use to reach the workspace default storage account. Required when
# the storage firewall is enabled. Distinct from the Unity Catalog connector in modules/catalog, which reaches the
# catalog's own storage account - each identity is scoped to only its own storage.
resource "azurerm_databricks_access_connector" "default_storage" {
  count = var.secure_workspace_default_storage ? 1 : 0

  name                = "id-databricks-ws-${var.resource_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  identity {
    type = "SystemAssigned"
  }
  tags = var.tags
}
