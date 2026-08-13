# Create workspace subnets
resource "azurerm_subnet" "workspace_subnets" {
  for_each = local.workspace_subnets

  name                 = "${module.naming.subnet.name}-${each.key}"
  resource_group_name  = azurerm_virtual_network.this.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name

  address_prefixes = [module.subnet_addrs.network_cidr_blocks[each.key]]

  delegation {
    name = "databricks-container-subnet-delegation"

    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "workspace_subnets" {
  for_each = azurerm_subnet.workspace_subnets

  subnet_id                 = each.value.id
  network_security_group_id = azurerm_network_security_group.this.id
}

# Create the privatelink subnet
resource "azurerm_subnet" "privatelink" {
  name                 = "${module.naming.subnet.name}-pl"
  resource_group_name  = azurerm_virtual_network.this.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name

  address_prefixes = [module.subnet_addrs.network_cidr_blocks["privatelink"]]

  # Make this a private subnet: nothing here gets an implicit, Microsoft-owned default outbound IP. This is a
  # defense-in-depth guardrail, not a functional requirement - private endpoints are inbound NICs and do not originate
  # outbound internet traffic, so disabling default outbound access does not change how the backend/storage PEs behave.
  # It only ensures that any resource later placed in this subnet cannot silently acquire implicit internet egress.
  #
  # The workspace host/container subnets deliberately do NOT set this: they are delegated to Microsoft.Databricks, and
  # Azure does not apply the private-subnet property to delegated subnets - their egress is governed by the Databricks
  # service (secure cluster connectivity), not by this flag.
  default_outbound_access_enabled = false
}

# Create any extra subnets
resource "azurerm_subnet" "extra" {
  for_each = var.extra_subnets

  name                 = each.value.name
  resource_group_name  = azurerm_virtual_network.this.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [module.subnet_addrs.network_cidr_blocks[each.value.name]]
}
