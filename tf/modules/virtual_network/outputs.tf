locals {
  all_subnet_ids = merge(
    {
      privatelink = azurerm_subnet.privatelink.id
    },
    { for k, v in azurerm_subnet.workspace_subnets : k => v.id },
    { for k, v in azurerm_subnet.extra : k => v.id }
  )
  all_subnet_names = merge(
    {
      privatelink = azurerm_subnet.privatelink.name
    },
    { for k, v in azurerm_subnet.workspace_subnets : k => v.name },
    { for k, v in azurerm_subnet.extra : k => v.name }
  )
}

output "dns_zone_ids" {
  description = "Private DNS Zone IDs"
  value = {
    dfs     = azurerm_private_dns_zone.dbfs_dfs.id
    blob    = azurerm_private_dns_zone.dbfs_blob.id
    backend = azurerm_private_dns_zone.backend.id
  }
}

output "subnet_ids" {
  description = "Subnet IDs"
  value       = local.all_subnet_ids
}

output "subnet_names" {
  description = "Subnet names"
  value       = local.all_subnet_names
}

output "resource_suffix" {
  description = "Resource suffix to use for naming down stream resources"
  value       = var.resource_suffix
}

output "tags" {
  description = "Tags of this spoke"
  value       = var.tags
}

output "vnet_name" {
  description = "Name of the VNet"
  value       = azurerm_virtual_network.this.name
}

output "vnet_id" {
  description = "ID of the VNet"
  value       = azurerm_virtual_network.this.id
}

output "public_subnet_network_security_group_association_id" {
  description = "ID of the public subnet network security group association"
  value       = azurerm_subnet_network_security_group_association.workspace_subnets["host"].id
}

output "private_subnet_network_security_group_association_id" {
  description = "ID of the private subnet network security group association"
  value       = azurerm_subnet_network_security_group_association.workspace_subnets["container"].id
}

output "network_configuration" {
  description = "Network configuration for use with the workspace module"
  value = {
    virtual_network_id                                   = azurerm_virtual_network.this.id
    private_subnet_id                                    = azurerm_subnet.workspace_subnets["container"].id
    public_subnet_id                                     = azurerm_subnet.workspace_subnets["host"].id
    private_endpoint_subnet_id                           = azurerm_subnet.privatelink.id
    private_subnet_network_security_group_association_id = azurerm_subnet_network_security_group_association.workspace_subnets["container"].id
    public_subnet_network_security_group_association_id  = azurerm_subnet_network_security_group_association.workspace_subnets["host"].id
  }
}

# Reachability to on-premises and to P2S clients depends on gateway transit rather than on any route this module
# creates: with use_remote_gateways set here and allow_gateway_transit on the hub side, Azure propagates the hub
# gateway's learned routes into this VNet as system routes.
output "hub_peering_uses_remote_gateways" {
  description = "Whether the hub peering enables use_remote_gateways, required for gateway transit to propagate routes"
  value       = try(azurerm_virtual_network_peering.peers["hub"].use_remote_gateways, false)
}

# Empty in the no-firewall topology. Non-empty only if route tables are reintroduced to override propagated routing.
output "route_table_ids" {
  description = "IDs of route tables created by this module"
  value       = []
}

output "network_cidr_blocks" {
  description = "CIDR allocations of this VNET"
  value       = module.subnet_addrs.network_cidr_blocks
}
