# Private connectivity from this spoke to the shared platform Key Vault.
#
# The vault itself is not managed here - it belongs to tf/platform and is supplied as var.key_vault_id. This module only
# creates the spoke-side path to it: a private DNS zone, a link from that zone to this spoke's VNet, and a private
# endpoint whose NIC takes an address from this spoke's private endpoint subnet.
#
# WHY THESE LIVE IN THE SPOKE, NOT THE PLATFORM RESOURCE GROUP
#
# A private DNS zone name is unique within a resource group, so a single privatelink.vaultcore.azure.net zone in the
# platform resource group could only exist once. A private endpoint registers an A-record named after its target resource,
# which for Key Vault is the vault name - so with one shared vault, every spoke's endpoint would write the *same* record
# name into that one zone. The second registration clobbers the first, and spoke A then resolves the vault to spoke B's
# NIC address, which it has no route to: VNet peering is not transitive and this topology has no firewall to hairpin
# through. The Azure Private Link DNS documentation describes the same failure - "This will cause a deletion of the
# initial A-record and result in resolution issues."
#
# One zone per spoke, in that spoke's own resource group, gives one A-record per zone pointing at the NIC that spoke can
# actually reach. It also means these resources are destroyed with the spoke, which is correct: they describe this
# workspace's access to the vault, not the vault itself.
#
# WHY THIS IS OPTIONAL
#
# CMK does not need it. Neither unwrap call reaches the vault through a private endpoint - managed services keys are
# unwrapped by the Databricks control plane and managed disk keys by the Disk Encryption Set, both of which sit outside
# every spoke VNet and arrive via the vault's trusted-services bypass. Terraform does not need it either, since the keys
# are created through ARM's control plane. This exists for in-VNet data-plane callers: a Key Vault-backed secret scope
# from classic compute, or an operator working from a VM in the VNet.

resource "azurerm_private_dns_zone" "vaultcore" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name

  tags = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vaultcore" {
  name                  = "${var.resource_suffix}-keyvault-vnetlink"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.vaultcore.name
  virtual_network_id    = var.virtual_network_id

  tags = var.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "${module.naming.private_endpoint.name}-kv"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

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
