output "spoke_workspace_info" {
  description = "Information for the deployed spoke Databricks Workspace"
  value = {
    resource_group_name = module.spoke_workspace.resource_group_name
    workspace_url       = module.spoke_workspace.workspace_url
    workspace_id        = module.spoke_workspace.workspace_id

    # Azure resource ID, as distinct from workspace_id above, which is the Databricks account-console ID
    id = module.spoke_workspace.id
  }
}

output "spoke_workspace_catalog" {
  description = "Name of the catalog created for the spoke workspace"
  value       = module.spoke_catalog.catalog_name
}

# The shared vault this spoke is bound to. Owned by the platform layer in tf/platform, not by this state - echoed here so
# a deployed spoke records which vault its keys came from without anyone having to consult the platform state.
output "spoke_keyvault" {
  description = "The shared platform Key Vault this spoke uses for CMK. Null when CMK is disabled. The private endpoint to this vault is owned by tf/platform, so it is not reported here."
  value = var.cmk_enabled ? {
    key_vault_id  = local.cmk_keyvault_id
    key_vault_uri = local.cmk_keyvault_uri
  } : null
}

# ------------------------------------------------------------------
# Peering handoff
#
# Azure VNet peering is two independent resources, one in each VNet, and the link stays "Initiated" until both exist. This
# configuration creates at most the spoke half - see var.create_hub_peering - so these outputs supply whatever is left
# over, either the hub half alone or both.
#
# The hub half cannot be created in advance when this configuration builds the VNet: it needs the spoke VNet's resource
# ID, which does not exist until then. So it is a post-apply handoff rather than a prerequisite.
locals {
  # Null when create_hub_peering is false and no hub was supplied - the hub outputs then have nothing to report
  hub_vnet_parsed = var.existing_hub_vnet != null ? provider::azurerm::parse_resource_id(var.existing_hub_vnet.vnet_id) : null

  spoke_vnet_id   = length(module.spoke_network) > 0 ? module.spoke_network[0].vnet_id : var.existing_workspace_vnet.network_configuration.virtual_network_id
  spoke_vnet_name = length(module.spoke_network) > 0 ? module.spoke_network[0].vnet_name : null

  hub_peering_name   = local.hub_vnet_parsed != null ? "from-${local.hub_vnet_parsed.resource_name}-to-${coalesce(local.spoke_vnet_name, "spoke")}-peer" : null
  spoke_peering_name = local.hub_vnet_parsed != null ? "from-${coalesce(local.spoke_vnet_name, "spoke")}-to-${local.hub_vnet_parsed.resource_name}-peer" : null

  # True when this configuration built the VNet but not the peering, so the spoke half is outstanding too. That half
  # carries use_remote_gateways, which is easy to omit when creating the peering by hand - and omitting it silently costs
  # all on-premises reachability for classic compute, since no UDRs are created.
  spoke_peering_outstanding = var.create_hub_peering == false && length(module.spoke_network) > 0
}

output "hub_peering_required" {
  description = <<-EOT
    Values needed to create the peering halves this configuration did not. Until both halves exist, the peering stays
    "Initiated"/"Remote sync required" and no traffic flows between the spoke and the hub. Null when no hub VNet was
    supplied.
  EOT

  value = local.hub_vnet_parsed == null ? null : {
    hub_subscription_id = local.hub_vnet_parsed.subscription_id
    hub_resource_group  = local.hub_vnet_parsed.resource_group_name
    hub_vnet_name       = local.hub_vnet_parsed.resource_name
    spoke_vnet_id       = local.spoke_vnet_id
    suggested_name      = local.hub_peering_name

    # Whether the spoke half is also outstanding. False in the default topology, where Terraform created it.
    spoke_peering_required       = local.spoke_peering_outstanding
    spoke_peering_suggested_name = local.spoke_peering_name

    # allow_gateway_transit on the hub side is what permits the spoke's use_remote_gateways, which the on-premises
    # routes to next_hop_type VirtualNetworkGateway depend on. Without it the spoke cannot use the hub's VPN gateway.
    required_settings = {
      allow_virtual_network_access = true
      allow_gateway_transit        = true
      allow_forwarded_traffic      = true
      use_remote_gateways          = false
    }

    # The mirror image on the spoke side. Only relevant when spoke_peering_required is true.
    spoke_required_settings = {
      allow_virtual_network_access = true
      allow_gateway_transit        = false
      allow_forwarded_traffic      = true
      use_remote_gateways          = true
    }
  }
}

output "hub_peering_command" {
  description = "Copy-paste az CLI commands for the peering halves this configuration did not create. Null when no hub VNet was supplied."

  value = local.hub_vnet_parsed == null ? null : join("\n", compact([
    <<-EOT
      # Hub -> spoke. Run as a principal with Network Contributor on the hub VNet:
      az network vnet peering create \
        --name ${local.hub_peering_name} \
        --resource-group ${local.hub_vnet_parsed.resource_group_name} \
        --vnet-name ${local.hub_vnet_parsed.resource_name} \
        --subscription ${local.hub_vnet_parsed.subscription_id} \
        --remote-vnet ${local.spoke_vnet_id} \
        --allow-vnet-access \
        --allow-gateway-transit \
        --allow-forwarded-traffic
    EOT
    ,

    # Only emitted when create_hub_peering is false. --allow-remote-gateways is the CLI flag for use_remote_gateways and
    # is what makes the hub gateway's routes propagate into the spoke; leaving it off is the silent failure mode.
    !local.spoke_peering_outstanding ? null : <<-EOT
      # Spoke -> hub. This configuration did not create this half (create_hub_peering = false). Run as a principal with
      # peer/action on BOTH networks - that requirement is why this half was left out:
      az network vnet peering create \
        --name ${local.spoke_peering_name} \
        --resource-group ${local.resource_group_name} \
        --vnet-name ${local.spoke_vnet_name} \
        --subscription ${var.subscription_id} \
        --remote-vnet ${var.existing_hub_vnet.vnet_id} \
        --allow-vnet-access \
        --allow-forwarded-traffic \
        --allow-remote-gateways
    EOT
    ,

    <<-EOT
      # Then confirm both sides report "Connected":
      az network vnet peering list \
        --resource-group ${local.hub_vnet_parsed.resource_group_name} \
        --vnet-name ${local.hub_vnet_parsed.resource_name} \
        --subscription ${local.hub_vnet_parsed.subscription_id} \
        --query "[].{name:name,state:peeringState,sync:peeringSyncLevel}" -o table
    EOT
  ]))
}
