# Reads the CMK configuration off a deployed workspace, so the integration test can assert that all three CMK scopes use
# a customer key rather than a platform-managed one.
#
# Azure reports this per scope as `keySource`: "Microsoft.Keyvault" for a customer-managed key, "Default" for the
# platform-managed key. The three scopes live in two different places in the workspace payload:
#
#   properties.encryption.entities.managedServices  - control plane
#   properties.encryption.entities.managedDisk      - classic compute cache
#   properties.parameters.encryption.value          - DBFS root (workspace storage account)
#
# This confirms the workspace is *configured* for CMK. It does not prove a key was exercised - that would need Key Vault
# diagnostic logging and a search for KeyWrap/KeyUnwrap events. Losing access to a configured key surfaces at cluster
# start as KeyVaultAccessForbidden.
data "azapi_resource" "workspace" {
  type        = "Microsoft.Databricks/workspaces@2024-05-01"
  resource_id = var.workspace_id

  # Exports the whole parameters object rather than individual paths. A path that is not exported reads as absent, which
  # the try() defaults below would quietly turn into "not enabled" - a false pass for a security assertion.
  response_export_values = [
    "properties.encryption",
    "properties.parameters",
  ]
}

locals {
  encryption = try(data.azapi_resource.workspace.output.properties.encryption, {})
  entities   = try(local.encryption.entities, {})

  # Key source per CMK scope, defaulting to "Default" (the platform-managed key) when a scope is absent
  key_sources = {
    managed_services = try(local.entities.managedServices.keySource, "Default")
    managed_disk     = try(local.entities.managedDisk.keySource, "Default")
    dbfs_root        = try(data.azapi_resource.workspace.output.properties.parameters.encryption.value.keySource, "Default")
  }

  # Vault URI per scope, so a caller can confirm all three point at the expected vault
  key_vault_uris = {
    managed_services = try(local.entities.managedServices.keyVaultProperties.keyVaultUri, null)
    managed_disk     = try(local.entities.managedDisk.keyVaultProperties.keyVaultUri, null)
    dbfs_root        = try(data.azapi_resource.workspace.output.properties.parameters.encryption.value.keyvaulturi, null)
  }
}
