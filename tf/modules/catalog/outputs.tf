output "storage_account_id" {
  description = "ID of the Azure Storage Account for this catalog"
  value       = azurerm_storage_account.unity_catalog.id
}

output "external_location_id" {
  description = "ID of the Databricks external location"
  value       = databricks_external_location.external_location.id
}

output "access_connector_mi_id" {
  description = "Managed identity ID of the access connector"
  value       = local.access_connector_mi_id
}

output "catalog_name" {
  description = "Name of the catalog"
  value       = databricks_catalog.catalog.name
}

# Exposed so the placement can be asserted in tests. Defaults to the workspace resource group.
output "access_connector_resource_group" {
  description = "Resource group holding the Unity Catalog access connector"
  value       = azurerm_databricks_access_connector.unity_catalog.resource_group_name
}
