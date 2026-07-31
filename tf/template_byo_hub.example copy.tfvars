databricks_account_id = "00000000-0000-0000-0000-000000000000"

# BYO Hub (no hub created by SRA)
create_hub              = false
create_workspace_vnet   = true
databricks_metastore_id = "00000000-0000-0000-0000-000000000000"

# Basic configuration
location        = "westus2"
subscription_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
resource_suffix = "spokenonet"

tags = {
  Owner = "user@example.com"
}

# Use existing resource group
# existing_resource_group_name = "rg-example"

# BYO hub integration (from external hub)
existing_cmk_ids = {
  key_vault_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-hub/providers/Microsoft.KeyVault/vaults/kv-example-hub"
  managed_disk_key_id     = "https://example-keyvault.vault.azure.net/keys/example/fdf067c93bbb4b22bff4d8b7a9a56217"
  managed_services_key_id = "https://example-keyvault.vault.azure.net/keys/example/fdf067c93bbb4b22bff4d8b7a9a56217"
}

# Existing hub VNET details (for spoke network peering)
existing_hub_vnet = {
  route_table_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-external-hub/providers/Microsoft.Network/routeTables/rt-external"
  vnet_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-external-hub/providers/Microsoft.Network/virtualNetworks/vnet-external-hub"
}

# Network egress configuration
allowed_fqdns    = []
hub_allowed_urls = []

# Serverless configuration
existing_ncc_id = "00000000-0000-0000-0000-000000000000"
existing_network_policy_id = "np-example-restrictive"

# Workspace VNET configuration
workspace_vnet = {
  cidr = "10.0.4.0/22"
}