# Create virtual network peerings from this network to it's peers
resource "azurerm_virtual_network_peering" "peers" {
  for_each = var.virtual_network_peerings

  name                      = each.value.name == "" ? "from-${azurerm_virtual_network.this.name}-to-${provider::azurerm::parse_resource_id(each.value.remote_virtual_network_id).resource_name}-peer" : each.value.name
  remote_virtual_network_id = each.value.remote_virtual_network_id
  resource_group_name       = azurerm_virtual_network.this.resource_group_name
  virtual_network_name      = azurerm_virtual_network.this.name

  # If the property isn't explicitly defined in the map, default safely to false
  allow_gateway_transit = try(each.value.allow_gateway_transit, false)
  use_remote_gateways   = try(each.value.use_remote_gateways, false)
  
  # Forward-thinking best practice: match traffic parameters
  allow_forwarded_traffic = try(each.value.allow_forwarded_traffic, true)
}
