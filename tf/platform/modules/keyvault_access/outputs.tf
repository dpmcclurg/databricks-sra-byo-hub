output "private_endpoint_id" {
  description = "Resource ID of the shared Key Vault private endpoint"
  value       = azurerm_private_endpoint.key_vault.id
}

output "private_endpoint_ip_address" {
  description = "Private IP the vault resolves to inside the linked VNets. The single A-record in the shared zone points here."
  value       = try(azurerm_private_endpoint.key_vault.private_service_connection[0].private_ip_address, null)
}

output "private_dns_zone_id" {
  description = "Resource ID of the shared privatelink.vaultcore.azure.net zone"
  value       = azurerm_private_dns_zone.vaultcore.id
}

output "private_dns_zone_name" {
  description = "Name of the private DNS zone that resolves the vault for every linked spoke"
  value       = azurerm_private_dns_zone.vaultcore.name
}

output "resource_group_name" {
  description = "Resource group holding the zone, links, and endpoint. The security resource group, alongside the vault."
  value       = azurerm_private_dns_zone.vaultcore.resource_group_name
}

output "linked_virtual_network_ids" {
  description = "Spoke VNets linked to the zone, keyed as supplied. Each added spoke is a link here rather than a new zone."
  value       = { for k, v in azurerm_private_dns_zone_virtual_network_link.vaultcore : k => v.virtual_network_id }
}
