# Private connectivity to the shared Key Vault: a privatelink.vaultcore.azure.net zone, a private endpoint whose NIC takes
# an address from a pre-existing spoke subnet, and one VNet link per spoke that should resolve the vault privately.
#
# These live with the vault because one shared vault gets ONE endpoint, which is what makes a single shared zone correct.
# An endpoint per spoke would not work with a shared zone: the A-record is named after the endpoint's target, so N
# endpoints pointing at the same vault all register the same name, and the second registration clobbers the first. One
# platform-owned endpoint avoids that by construction - one A-record, one NIC, reachable from every peered spoke, with the
# zone shared through VNet links as private DNS zones are meant to be. Azure creates the NIC in the endpoint's own resource
# group, so it follows this placement with no Terraform resource of its own.
#
# Both the subnet and the linked VNets must exist before this layer applies; see var.private_endpoint_subnet_id.
#
# This is optional because CMK does not use it: managed services keys are unwrapped by the Databricks control plane and
# managed disk keys by the Disk Encryption Set, both outside every spoke VNet and reaching the vault through its
# trusted-services bypass, and the keys themselves are created through ARM. It exists for in-VNet data-plane callers, such
# as a Key Vault-backed secret scope from classic compute.

resource "azurerm_private_dns_zone" "vaultcore" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name

  tags = var.tags
}

# One link per spoke VNet that should resolve the vault privately. Adding a spoke is a new entry in this map, not a new
# zone - which is the point of owning the endpoint here rather than per spoke.
resource "azurerm_private_dns_zone_virtual_network_link" "vaultcore" {
  for_each = var.spoke_virtual_network_ids

  name                  = "${each.key}-keyvault-vnetlink"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.vaultcore.name
  virtual_network_id    = each.value

  tags = var.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "${module.naming.private_endpoint.name}-kv"
  location            = var.location
  resource_group_name = var.resource_group_name

  # A subnet in one of the spoke VNets, created ahead of this layer by the network team. The endpoint is reachable from
  # every peered spoke, so which spoke hosts the NIC is a placement decision, not an access-scoping one.
  subnet_id = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "keyvault"
    private_connection_resource_id = var.key_vault_id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "keyvault"
    private_dns_zone_ids = [azurerm_private_dns_zone.vaultcore.id]
  }

  tags = var.tags
}

module "naming" {
  source  = "Azure/naming/azurerm"
  version = "~>0.4"
  suffix  = [var.resource_suffix]
}
