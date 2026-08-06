output "private_endpoint_id" {
  description = "Resource ID of the Key Vault private endpoint"
  value       = azurerm_private_endpoint.key_vault.id
}

output "private_dns_zone_id" {
  description = "Resource ID of this spoke's privatelink.vaultcore.azure.net zone"
  value       = azurerm_private_dns_zone.vaultcore.id
}

output "private_dns_zone_name" {
  description = "Name of the private DNS zone, so a caller can confirm which zone resolves the vault in this spoke"
  value       = azurerm_private_dns_zone.vaultcore.name
}
