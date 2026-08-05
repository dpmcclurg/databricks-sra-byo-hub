# This project deploys a spoke workspace into an existing, customer-managed hub. It does not create a hub, a hub
# workspace, or an Azure Firewall - all hub resources (VNet, gateway, metastore, NCC, network policy, CMK) are supplied
# as existing_* inputs. See the "Bring-your-own hub, no Azure Firewall" section of the README.
locals {
  resource_group_name = var.create_workspace_resource_group ? azurerm_resource_group.spoke[0].name : var.existing_resource_group_name

  # Tag names are lowercased before use. ARM lowercases tag names on some resource types - Microsoft.KeyVault/vaults/keys
  # is one - so a tag supplied as "Owner" is stored as "owner" there but kept as "Owner" elsewhere. Normalising here
  # means config matches what Azure stores on every resource type, instead of planning a change that can never converge.
  # Only names are lowered; values are left alone, since Azure preserves those and they can be case-significant.
  tags = { for name, value in var.tags : lower(name) => value }

  # CMK keys come from a vault this configuration creates in the spoke, or from a vault supplied as an existing_* input.
  # A vault must be in the same region and tenant as the workspace, so a central vault can only serve spokes in its own
  # region - see the "Customer-managed keys" section of the README.
  create_keyvault = var.cmk_enabled && var.cmk_source == "create"

  cmk_keyvault_id             = local.create_keyvault ? module.spoke_keyvault[0].key_vault_id : try(var.existing_cmk_ids.key_vault_id, null)
  cmk_managed_disk_key_id     = local.create_keyvault ? module.spoke_keyvault[0].managed_disk_key_id : try(var.existing_cmk_ids.managed_disk_key_id, null)
  cmk_managed_services_key_id = local.create_keyvault ? module.spoke_keyvault[0].managed_services_key_id : try(var.existing_cmk_ids.managed_services_key_id, null)

  # Falls back to the managed services key when an existing vault does not supply a dedicated DBFS root key, so that
  # existing_cmk_ids stays backwards compatible.
  cmk_dbfs_root_key_id = local.create_keyvault ? module.spoke_keyvault[0].dbfs_root_key_id : try(coalesce(var.existing_cmk_ids.dbfs_root_key_id, var.existing_cmk_ids.managed_services_key_id), null)
}

resource "azurerm_resource_group" "spoke" {
  count = var.create_workspace_resource_group ? 1 : 0

  location = var.location
  name     = "rg-${var.resource_suffix}"
  tags     = local.tags
}

module "spoke_network" {
  source = "./modules/virtual_network"
  count  = var.workspace_vnet != null ? 1 : 0

  # Azure Parameters
  resource_suffix     = var.resource_suffix
  tags                = local.tags
  resource_group_name = local.resource_group_name
  location            = var.location

  # Networking Parameters
  vnet_cidr = var.workspace_vnet.cidr

  # No route table is created. With gateway transit (allow_gateway_transit on the hub peering, use_remote_gateways
  # here), Azure propagates the hub gateway's learned routes - on-premises prefixes, VNet-to-VNet, and the P2S client
  # pool - into this VNet as system routes. A UDR would only be needed to override that, e.g. to force egress through
  # an NVA, which this no-firewall topology does not do.
  virtual_network_peerings = {
    hub = {
      remote_virtual_network_id = var.existing_hub_vnet.vnet_id

      # Required so the spoke can reach on-premises through the existing hub's VPN gateway
      allow_gateway_transit = false
      use_remote_gateways   = true
    }
  }
  workspace_subnets = {
    new_bits = var.workspace_vnet.new_bits
  }
}

# Key Vault and CMKs for this spoke. Skipped when cmk_enabled is false, or when the keys are supplied from an existing
# vault via existing_cmk_ids.
module "spoke_keyvault" {
  source = "./modules/keyvault"
  count  = local.create_keyvault ? 1 : 0

  resource_suffix     = var.resource_suffix
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = local.tags

  tenant_id                = data.azurerm_client_config.current.tenant_id
  provisioner_principal_id = data.azurerm_client_config.current.object_id

  # The vault's private endpoint and DNS zone live in the spoke
  private_endpoint_subnet_id = var.create_workspace_vnet ? module.spoke_network[0].subnet_ids["privatelink"] : var.existing_workspace_vnet.network_configuration.private_endpoint_subnet_id
  virtual_network_id         = var.create_workspace_vnet ? module.spoke_network[0].vnet_id : var.existing_workspace_vnet.network_configuration.virtual_network_id
}

module "spoke_workspace" {
  source = "./modules/workspace"

  # Azure/Network parameters
  location                     = var.location
  resource_suffix              = var.resource_suffix
  resource_group_name          = local.resource_group_name
  tags                         = local.tags
  enhanced_security_compliance = var.workspace_security_compliance
  name_overrides               = var.workspace_name_overrides
  network_configuration        = var.create_workspace_vnet ? module.spoke_network[0].network_configuration : var.existing_workspace_vnet.network_configuration
  dns_zone_ids                 = var.create_workspace_vnet ? module.spoke_network[0].dns_zone_ids : var.existing_workspace_vnet.dns_zone_ids

  # KMS parameters
  is_kms_enabled          = var.cmk_enabled
  managed_disk_key_id     = local.cmk_managed_disk_key_id
  managed_services_key_id = local.cmk_managed_services_key_id
  dbfs_root_key_id        = local.cmk_dbfs_root_key_id
  key_vault_id            = local.cmk_keyvault_id

  # Account parameters - all supplied from the existing hub
  ncc_id                   = var.existing_ncc_id
  ncc_name                 = var.existing_ncc_name
  network_policy_id        = var.existing_network_policy_id
  metastore_id             = var.databricks_metastore_id
  provisioner_principal_id = data.azurerm_client_config.current.object_id
  databricks_account_id    = var.databricks_account_id

  # Ordering matters on destroy, not on create.
  #
  # The workspace already receives the vault ID and the three key IDs above, so creation is ordered correctly by those
  # data dependencies. What is *not* covered is the vault's access policy for the Azure Databricks service principal:
  # nothing downstream consumes it, so it is a leaf in the graph and Terraform is free to delete it in parallel with the
  # workspace teardown.
  #
  # That breaks destroy. Removing the DBFS root CMK from the workspace is a workspace *update*, and Databricks
  # re-validates [Get, Wrap, Unwrap] against the vault when it runs. If the service principal's policy is already gone,
  # the update fails with a 403 and the destroy stops partway through:
  #
  #   WorkspaceUpdateFailed: Invalid permissions on the specified KeyVault ... does not have keys get permission
  #
  # Depending on the whole module keeps every workspace resource ordered before every vault resource on destroy, which
  # covers that policy and any other leaf added to the vault module later. This is a race, so a destroy can pass by luck
  # when the ordering is missing.
  depends_on = [module.spoke_keyvault]
}

module "spoke_catalog" {
  source = "./modules/catalog"

  catalog_name         = module.spoke_workspace.resource_suffix
  is_default_namespace = true

  # Azure/Network parameters
  dns_zone_ids        = module.spoke_workspace.dns_zone_ids
  location            = var.location
  resource_group_name = module.spoke_workspace.resource_group_name
  resource_suffix     = module.spoke_workspace.resource_suffix
  subnet_id           = module.spoke_workspace.subnet_ids.privatelink
  tags                = module.spoke_workspace.tags

  # Account parameters
  databricks_account_id = var.databricks_account_id
  metastore_id          = var.databricks_metastore_id
  ncc_id                = module.spoke_workspace.ncc_id
  ncc_name              = module.spoke_workspace.ncc_name

  force_destroy = var.catalog_force_destroy

  providers = {
    databricks.workspace = databricks.spoke
  }
}
