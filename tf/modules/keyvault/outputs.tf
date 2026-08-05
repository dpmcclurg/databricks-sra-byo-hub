output "key_vault_id" {
  description = "Resource ID of the Key Vault"
  value       = azurerm_key_vault.this.id
}

output "key_vault_uri" {
  description = "URI of the Key Vault"
  value       = azurerm_key_vault.this.vault_uri
}

output "purge_protection_enabled" {
  description = "Whether purge protection is enabled on the vault"
  value       = azurerm_key_vault.this.purge_protection_enabled
}

output "public_network_access_enabled" {
  description = "Whether the vault allows public network access"
  value       = azurerm_key_vault.this.public_network_access_enabled
}

# Versioned key IDs. Databricks requires a specific key version rather than "latest", so these deliberately use .id
# (which includes the version) rather than .versionless_id. Rotating a key therefore requires a Terraform apply to
# pick up the new version.
output "managed_services_key_id" {
  description = "Versioned ID of the managed services CMK"
  value       = azurerm_key_vault_key.managed_services.id
}

output "managed_disk_key_id" {
  description = "Versioned ID of the managed disk CMK"
  value       = azurerm_key_vault_key.managed_disk.id
}
