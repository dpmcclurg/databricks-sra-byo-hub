# Platform layer: the shared Key Vault and CMKs for one subscription, in one region.
#
# Apply this ONCE before any spoke workspace. Then run
#   terraform output -raw spoke_tfvars_snippet
# and paste the result into each spoke's var file in tf/.

subscription_id = "00000000-0000-0000-0000-000000000000"

# Must match the location of every spoke workspace served by this vault. A vault cannot serve a workspace in another
# region, so a second region needs a second instance of this configuration and its own state.
location = "eastus2"

resource_suffix = "dbx-prod"

# Explicit, deterministic names are strongly preferred for this shared vault. With a generated name, losing this state
# would produce a second empty vault while every spoke still points at the first one's keys - orphaned but alive, so
# nothing fails loudly. Vault names are globally unique, 3-24 chars.
key_vault_name  = "kv-dbx-prod-eastus2"
key_name_prefix = "kvk-dbx-prod"

# Object ID of the AzureDatabricks enterprise app, used for the CMK role grant. Leave unset for a local run as yourself
# (resolved via Entra directory read, which your user account has). REQUIRED for any UAMI/CI run: the platform UAMI has
# no directory read and cannot be granted it, so pin the value here instead. Resolve it once as yourself:
#   az ad sp show --id 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query id -o tsv
# The appId is constant across tenants; only this object ID is tenant-specific (and stable).
# databricks_service_principal_object_id = "00000000-0000-0000-0000-000000000000"

# Defaults to rg-<resource_suffix>-security
# security_resource_group_name = "rg-dbx-prod-security"

# Deploy into a centrally-governed resource group instead of creating one
# create_security_resource_group        = false
# existing_security_resource_group_name = "rg-prod-security"

# Private access to the shared vault: one private endpoint, one privatelink.vaultcore.azure.net zone, and one VNet link
# per spoke, all in the security resource group with the vault. Azure creates the endpoint's NIC there too.
#
# This layer does not create the networking below - the spoke VNets and subnets must already exist. Not required for CMK
# either: the Databricks control plane and the Disk Encryption Set reach the vault through its trusted-services bypass,
# and the keys are created through ARM. Set create_key_vault_private_endpoint = false where nothing inside a VNet calls
# the vault's data plane.
key_vault_private_endpoint_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/privatelink"

# One entry per spoke that should resolve the vault privately. Adding a spoke adds a link here and a re-apply of this
# layer - not a second zone, since one platform-owned endpoint means one A-record.
spoke_virtual_network_ids = {
  spoke1 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
}

# create_key_vault_private_endpoint = false

tags = {
  owner       = "user@example.com"
  environment = "prod"
}
