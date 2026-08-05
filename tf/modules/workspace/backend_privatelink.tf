# Define a private endpoint resource for the backend
resource "azurerm_private_endpoint" "backend" {
  count = var.create_backend_private_endpoint ? 1 : 0

  name                = "${lookup(var.name_overrides, "private_endpoint", module.naming.private_endpoint.name_unique)}-backend"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.network_configuration.private_endpoint_subnet_id

  # Configure the private service connection
  private_service_connection {
    name                           = "ple-${var.resource_suffix}-backend"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    is_manual_connection           = false
    subresource_names              = ["databricks_ui_api"]
  }

  # Configure the private DNS zone group
  private_dns_zone_group {
    name                 = "private-dns-zone-backend"
    private_dns_zone_ids = [var.dns_zone_ids.backend]
  }

  # This resource does not literally depend on the CMK access policies. However, granting the workspace identities
  # access to the vault puts the workspace in an "updating" state, and creating this private endpoint does the same, so
  # running both at once causes one of them to fail.
  depends_on = [
    azurerm_key_vault_access_policy.dbstorage,
    azurerm_key_vault_access_policy.dbmanageddisk,
  ]

  tags = var.tags
}
