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
  description = "Whether the vault allows public network access. True by design - the firewall below is what restricts access, since the provisioner's data-plane calls cannot traverse the private endpoint."
  value       = azurerm_key_vault.this.public_network_access_enabled
}

output "network_acls_default_action" {
  description = "Default action of the vault firewall. Deny means only the bypass and IP rules reach the vault."
  value       = one(azurerm_key_vault.this.network_acls).default_action
}

# Key names are known at plan time, unlike the versioned URIs, which come from the ARM response
output "key_names" {
  description = "Names of the CMKs created in the vault, one per CMK scope"
  value = [
    azapi_resource.managed_services_key.name,
    azapi_resource.dbfs_root_key.name,
    azapi_resource.managed_disk_key.name,
  ]
}

output "network_acls_bypass" {
  description = "Vault firewall bypass. AzureServices is required for CMK - the Databricks control plane and the Disk Encryption Set both reach the vault this way."
  value       = one(azurerm_key_vault.this.network_acls).bypass
}

# Versioned key IDs. Databricks requires a specific key version rather than "latest", so these use the ARM response's
# keyUriWithVersion. Rotating a key therefore requires a Terraform apply to pick up the new version.
output "managed_services_key_id" {
  description = "Versioned ID of the managed services CMK"
  value       = azapi_resource.managed_services_key.output.properties.keyUriWithVersion
}

output "dbfs_root_key_id" {
  description = "Versioned ID of the DBFS root CMK"
  value       = azapi_resource.dbfs_root_key.output.properties.keyUriWithVersion
}

output "managed_disk_key_id" {
  description = "Versioned ID of the managed disk CMK"
  value       = azapi_resource.managed_disk_key.output.properties.keyUriWithVersion
}
