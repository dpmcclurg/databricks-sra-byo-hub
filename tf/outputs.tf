output "spoke_workspace_info" {
  description = "Information for the deployed spoke Databricks Workspace"
  value = {
    resource_group_name = module.spoke_workspace.resource_group_name
    workspace_url       = module.spoke_workspace.workspace_url
    workspace_id        = module.spoke_workspace.workspace_id
  }
}

output "spoke_workspace_catalog" {
  description = "Name of the catalog created for the spoke workspace"
  value       = module.spoke_catalog.catalog_name
}

# ------------------------------------------------------------------
# Hub-side peering handoff
#
# Azure VNet peering is two independent resources - one in each VNet - and the link stays in the "Initiated" state
# until both exist. This configuration only creates the spoke half, because the hub is customer-managed and out of
# scope (see the existing_* inputs).
#
# The hub half cannot be created before this apply: it needs the spoke VNet's resource ID, which does not exist until
# the spoke network is built. So it is a post-apply step for the hub owner, not a prerequisite. These outputs give them
# the exact values and command.
locals {
  hub_vnet_parsed = provider::azurerm::parse_resource_id(var.existing_hub_vnet.vnet_id)

  spoke_vnet_id   = length(module.spoke_network) > 0 ? module.spoke_network[0].vnet_id : var.existing_workspace_vnet.network_configuration.virtual_network_id
  spoke_vnet_name = length(module.spoke_network) > 0 ? module.spoke_network[0].vnet_name : null

  hub_peering_name = "from-${local.hub_vnet_parsed.resource_name}-to-${coalesce(local.spoke_vnet_name, "spoke")}-peer"
}

output "hub_peering_required" {
  description = <<-EOT
    Details the hub owner needs to create the reciprocal (hub -> spoke) peering. Until it exists, the spoke peering
    stays disabled/"Remote sync required" and no traffic flows between the spoke and the hub.
  EOT

  value = {
    hub_subscription_id = local.hub_vnet_parsed.subscription_id
    hub_resource_group  = local.hub_vnet_parsed.resource_group_name
    hub_vnet_name       = local.hub_vnet_parsed.resource_name
    spoke_vnet_id       = local.spoke_vnet_id
    suggested_name      = local.hub_peering_name

    # allow_gateway_transit on the hub side is what permits the spoke's use_remote_gateways, which the on-premises
    # routes to next_hop_type VirtualNetworkGateway depend on. Without it the spoke cannot use the hub's VPN gateway.
    required_settings = {
      allow_virtual_network_access = true
      allow_gateway_transit        = true
      allow_forwarded_traffic      = true
      use_remote_gateways          = false
    }
  }
}

output "hub_peering_command" {
  description = "Copy-paste az CLI command for the hub owner to complete the peering after this apply."

  value = <<-EOT
    # Run as a principal with Network Contributor on the hub VNet:
    az network vnet peering create \
      --name ${local.hub_peering_name} \
      --resource-group ${local.hub_vnet_parsed.resource_group_name} \
      --vnet-name ${local.hub_vnet_parsed.resource_name} \
      --subscription ${local.hub_vnet_parsed.subscription_id} \
      --remote-vnet ${local.spoke_vnet_id} \
      --allow-vnet-access \
      --allow-gateway-transit \
      --allow-forwarded-traffic

    # Then confirm both sides report "Connected":
    az network vnet peering list \
      --resource-group ${local.hub_vnet_parsed.resource_group_name} \
      --vnet-name ${local.hub_vnet_parsed.resource_name} \
      --subscription ${local.hub_vnet_parsed.subscription_id} \
      --query "[].{name:name,state:peeringState,sync:peeringSyncLevel}" -o table
  EOT
}
