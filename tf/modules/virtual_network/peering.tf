# Create virtual network peerings from this network to it's peers.
#
# Azure models peering as two independent resources, one in each VNet. This creates only the local (spoke) half; the
# remote half must be created in the peer VNet before the link leaves the "Initiated" state. In BYO hub deployments the
# hub is customer-managed, so that half is a post-apply step for the hub owner - see the hub_peering_command output at
# the root module and the "Completing the hub peering" section of the README.
#
# Until the remote half exists, the peering shows as disabled with "Remote sync required" in the portal and carries no
# traffic. Note also that use_remote_gateways below only takes effect once the remote side sets allow_gateway_transit.
resource "azurerm_virtual_network_peering" "peers" {
  for_each = var.virtual_network_peerings

  name                      = each.value.name == "" ? "from-${azurerm_virtual_network.this.name}-to-${provider::azurerm::parse_resource_id(each.value.remote_virtual_network_id).resource_name}-peer" : each.value.name
  remote_virtual_network_id = each.value.remote_virtual_network_id
  resource_group_name       = azurerm_virtual_network.this.resource_group_name
  virtual_network_name      = azurerm_virtual_network.this.name

  # Defaults for these are supplied by the variable type, so they are always present
  allow_gateway_transit = each.value.allow_gateway_transit

  # Required for the spoke to use the hub's VPN gateway to reach on-premises networks. This is only half of the
  # requirement: the hub-side peering must set allow_gateway_transit = true, or the spoke cannot use the hub gateway and
  # the on-premises routes (next_hop_type VirtualNetworkGateway) will not carry traffic.
  use_remote_gateways = each.value.use_remote_gateways

  allow_forwarded_traffic = each.value.allow_forwarded_traffic
}
