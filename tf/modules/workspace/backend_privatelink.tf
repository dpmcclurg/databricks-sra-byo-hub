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

  # This resource does not literally depend on the CMK work in dbfs_root_cmk.tf. However, setting the DBFS root key puts
  # the workspace into an "Updating" state, and so does creating this private endpoint, so running them concurrently makes
  # one fail with InvalidWorkspaceProvisioningState.
  #
  # Strictly, only the DBFS root CMK is load-bearing now: the two role assignments touch Microsoft.Authorization rather
  # than Microsoft.Databricks, so they no longer put the workspace into Updating the way the access policies they replaced
  # did. They are kept in the list because the retry window makes this *more* important, not less - the DBFS root step can
  # now occupy several minutes of retries while RBAC propagates, widening the window in which a concurrently-created
  # private endpoint would collide. This is a race that passes by luck when the ordering is missing, so it is guarded
  # deliberately rather than narrowed.
  #
  # These are un-indexed references to counted resources, which is correct: depends_on on a counted resource covers all
  # instances and still works when the count is 0.
  depends_on = [
    azurerm_role_assignment.workspace_storage_cmk,
    azurerm_role_assignment.managed_disk_cmk,
    azapi_update_resource.dbfs_root_cmk,
  ]

  tags = var.tags
}
