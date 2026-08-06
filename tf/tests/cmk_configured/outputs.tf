output "key_sources" {
  description = "Key source per CMK scope. \"Microsoft.Keyvault\" means a customer-managed key, \"Default\" the platform-managed key."
  value       = local.key_sources
}

output "key_vault_uris" {
  description = "Vault URI backing each CMK scope, or null when that scope has no customer key"
  value       = local.key_vault_uris
}

output "managed_disk_rotation_to_latest_enabled" {
  description = "Whether the Disk Encryption Set follows later versions of the managed disk key on its own"
  value       = try(local.entities.managedDisk.rotationToLatestKeyVersionEnabled, false)
}

output "infrastructure_encryption_enabled" {
  description = "Whether the workspace has the second layer of platform encryption enabled"
  value       = try(data.azapi_resource.workspace.output.properties.parameters.requireInfrastructureEncryption.value, false)
}
