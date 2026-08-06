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
# cmk_enabled covers all three Azure Databricks CMK scopes together - managed services, DBFS root, and managed disks -
# plus infrastructure encryption. There is no per-scope toggle. Set it to false to use platform-managed keys instead.
cmk_enabled = true

# The shared Key Vault and keys come from the platform layer in tf/platform, which is applied once per subscription per
# region. Apply it first, then generate this block with:
#
#   cd ../tf/platform && terraform output -raw spoke_tfvars_snippet
#
# The `location` above must match the platform layer's location - Azure Databricks does not allow a vault to serve a
# workspace in another region, and nothing in Terraform catches a mismatch before Azure rejects the workspace create.
#
# Regenerate and re-apply after any key rotation: the key IDs are versioned, because Databricks requires a specific
# version rather than "latest".
platform_cmk = {
  key_vault_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dbx-prod-security/providers/Microsoft.KeyVault/vaults/kv-dbx-prod-eastus2"
  key_vault_uri = "https://kv-dbx-prod-eastus2.vault.azure.net/"

  managed_services_key_id = "https://kv-dbx-prod-eastus2.vault.azure.net/keys/kvk-dbx-prod-adb-services/fdf067c93bbb4b22bff4d8b7a9a56217"
  managed_disk_key_id     = "https://kv-dbx-prod-eastus2.vault.azure.net/keys/kvk-dbx-prod-adb-disk/fdf067c93bbb4b22bff4d8b7a9a56217"

  # DBFS root is applied through an ARM body, which takes the name and version separately rather than a versioned URI
  dbfs_root_key_name    = "kvk-dbx-prod-adb-dbfs"
  dbfs_root_key_version = "fdf067c93bbb4b22bff4d8b7a9a56217"
}

# Optionally place this spoke's two Databricks access connectors in the platform security resource group rather than the
# workspace resource group. Placement only - each spoke still gets its own connector pair, with roles scoped to its own
# storage accounts.
# place_access_connectors_in_security_rg = true
# security_resource_group_name           = "rg-dbx-prod-security"

# A private endpoint to the shared vault is created in this spoke by default. It is not required for CMK - neither unwrap
# call traverses it - so set this to false where nothing inside the VNet calls the vault's data plane.
# create_key_vault_private_endpoint = false

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