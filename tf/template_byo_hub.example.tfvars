databricks_account_id = "00000000-0000-0000-0000-000000000000"

# This project always deploys into an existing, customer-managed hub - it never creates one.
create_workspace_vnet   = true
databricks_metastore_id = "00000000-0000-0000-0000-000000000000"

# Basic configuration
location        = "westus2"
subscription_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
resource_suffix = "spokenonet"

tags = {
  owner = "user@example.com"
}

# Use existing resource group
# existing_resource_group_name = "rg-example"

# Customer-managed keys.
#
# cmk_source = "create" (the default) provisions a Key Vault and two keys in the spoke resource group. A vault must be
# in the same region and tenant as the workspace, so a central vault cannot serve spokes in another region.
cmk_enabled = true
cmk_source  = "create"

# Existing hub VNET details (for spoke network peering)
#
# There is no on_premises_cidrs setting and no route table. Classic compute reaches on-premises through gateway
# transit: the hub peering sets allow_gateway_transit, the spoke sets use_remote_gateways, and Azure propagates the
# hub gateway's learned routes (on-premises prefixes, VNet-to-VNet, and any P2S client pool) into the spoke VNet as
# system routes. See the "No Azure Firewall" section of the README.
#
# Note: this does not give serverless compute on-premises access. Serverless runs outside the spoke VNet.
existing_hub_vnet = {
  vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-external-hub/providers/Microsoft.Network/virtualNetworks/vnet-external-hub"
}

# Serverless configuration
existing_ncc_id            = "00000000-0000-0000-0000-000000000000"
existing_network_policy_id = "np-example-restrictive"

# Workspace VNET configuration
workspace_vnet = {
  cidr = "10.0.4.0/22"
}