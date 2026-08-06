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

# Reuse the resource group and VNet the network team already built.
#
# This is the expected shape in a landing zone: the spoke VNet has to exist before this configuration runs, because
# peering it to the hub needs permissions on the hub network that the Databricks provisioner does not hold. The network
# team creates a resource group for that VNet, and this configuration reuses it rather than creating its own. Fill in
# existing_workspace_vnet below and leave workspace_vnet null when doing this.
#
# create_workspace_resource_group = false
# existing_resource_group_name    = "rg-example"

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

  managed_services_key_id = "https://kv-eastus2.vault.azure.net/keys/kvk-dbx-prod-adb-services/00000000-0000-0000-0000-000000000000"
  managed_disk_key_id     = "https://kv-eastus2.vault.azure.net/keys/kvk-dbx-prod-adb-disk/00000000-0000-0000-0000-000000000000"

  # DBFS root is applied through an ARM body, which takes the name and version separately rather than a versioned URI
  dbfs_root_key_name    = "kvk-adb-dbfs"
  dbfs_root_key_version = "00000000000000000000000000000000"
}

# Optionally place this spoke's two Databricks access connectors in the platform security resource group rather than the
# workspace resource group. Placement only - each spoke still gets its own connector pair, with roles scoped to its own
# storage accounts.
# place_access_connectors_in_security_rg = true
# security_resource_group_name           = "rg-dbx-prod-security"

# The private endpoint to the shared vault is NOT configured here - it belongs to the platform layer, alongside the vault
# it points at. One shared vault gets one endpoint and one privatelink.vaultcore.azure.net zone; to let this spoke resolve
# the vault privately, add its VNet to spoke_virtual_network_ids in tf/platform and re-apply that layer.

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

# Set this to false when the principal running Terraform cannot peer to the hub.
#
# Even though this configuration only ever creates the *spoke* half, ARM authorizes that against the hub network: it
# requires Microsoft.Network/virtualNetworks/peer/action on the hub VNet, and the apply fails with
# LinkedAuthorizationFailed without it. That is common in a landing zone where the hub is in another subscription, and
# needs guest-user setup on top when it is in another tenant.
#
# With this false, the spoke VNet is still created and the workspace deploys normally - only the peering is left out. Run
# `terraform output hub_peering_command` afterwards for both halves, and note the spoke half must set
# --allow-remote-gateways or classic compute gets no on-premises routes at all.
#
# Leave this at true when the network team pre-built the VNet (create_workspace_vnet = false); there is no peering in this
# layer either way then, and existing_hub_vnet can be omitted entirely.
# create_hub_peering = false

# Serverless configuration
existing_ncc_id            = "00000000-0000-0000-0000-000000000000"
existing_network_policy_id = "np-example-restrictive"

# Workspace VNET configuration
workspace_vnet = {
  cidr = "10.0.4.0/22"
}