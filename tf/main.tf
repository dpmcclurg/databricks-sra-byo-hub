# This project deploys a spoke workspace into an existing, customer-managed hub. It does not create a hub, a hub
# workspace, or an Azure Firewall - all hub resources (VNet, gateway, metastore, NCC, network policy) are supplied
# as existing_* inputs. See the "Bring-your-own hub, no Azure Firewall" section of the README.
#
# The customer-managed keys are likewise not created here. They live in a shared Key Vault owned by the platform layer in
# tf/platform, which is applied once per subscription per region and outlives every workspace bound to it. This
# configuration is applied once per spoke workspace, with its own state, and consumes the vault via var.platform_cmk.
locals {
  resource_group_name = var.create_workspace_resource_group ? azurerm_resource_group.spoke[0].name : var.existing_resource_group_name

  # Resource group for resources whose lifecycle belongs to the platform rather than to this workspace. Only the access
  # connectors are placed here, and only when asked - everything else stays in the workspace resource group.
  access_connector_resource_group_name = var.place_access_connectors_in_security_rg ? var.security_resource_group_name : null

  # Tag names are lowercased before use. ARM lowercases tag names on some resource types, so a tag supplied as "Owner" is
  # stored as "owner" there but kept as "Owner" elsewhere. Normalising here means config matches what Azure stores on
  # every resource type, instead of planning a change that can never converge.
  # Only names are lowered; values are left alone, since Azure preserves those and they can be case-significant.
  tags = { for name, value in var.tags : lower(name) => value }

  # CMK inputs from the platform layer. Null when cmk_enabled is false, in which case the workspace uses
  # platform-managed keys and no vault is involved at all.
  cmk_keyvault_id             = try(var.platform_cmk.key_vault_id, null)
  cmk_keyvault_uri            = try(var.platform_cmk.key_vault_uri, null)
  cmk_managed_disk_key_id     = try(var.platform_cmk.managed_disk_key_id, null)
  cmk_managed_services_key_id = try(var.platform_cmk.managed_services_key_id, null)

  # The DBFS root CMK is applied as an ARM body rather than a typed attribute, and that body takes the vault URI, key
  # name, and version as separate properties instead of one versioned URI - so the platform layer emits the parts.
  cmk_dbfs_root_key_name    = try(var.platform_cmk.dbfs_root_key_name, null)
  cmk_dbfs_root_key_version = try(var.platform_cmk.dbfs_root_key_version, null)
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

# Private connectivity to the shared vault is NOT created here: one shared vault gets one private endpoint, so it lives
# with the vault in tf/platform along with its DNS zone and VNet links.
#
# To let this spoke resolve the vault privately, add its VNet to spoke_virtual_network_ids there and re-apply that layer.
# Nothing is needed here, and nothing is needed for CMK either - neither unwrap call traverses the endpoint.
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

  # Access connectors can be placed in the platform's security resource group. Null keeps them in the workspace group.
  access_connector_resource_group_name = local.access_connector_resource_group_name

  # KMS parameters. The keys come from the shared platform vault; this module grants that vault's wrap/unwrap role to the
  # workspace identities it creates, which do not exist until after the workspace is built.
  is_kms_enabled          = var.cmk_enabled
  key_vault_id            = local.cmk_keyvault_id
  key_vault_uri           = local.cmk_keyvault_uri
  managed_disk_key_id     = local.cmk_managed_disk_key_id
  managed_services_key_id = local.cmk_managed_services_key_id
  dbfs_root_key_name      = local.cmk_dbfs_root_key_name
  dbfs_root_key_version   = local.cmk_dbfs_root_key_version

  # Account parameters - all supplied from the existing hub
  ncc_id                   = var.existing_ncc_id
  ncc_name                 = var.existing_ncc_name
  network_policy_id        = var.existing_network_policy_id
  metastore_id             = var.databricks_metastore_id
  provisioner_principal_id = data.azurerm_client_config.current.object_id
  databricks_account_id    = var.databricks_account_id

  # No destroy-ordering depends_on is needed against the vault, and that is a consequence of the split rather than an
  # omission. Previously the vault's access policy for the Azure Databricks service principal lived in this same state as
  # a graph leaf, so Terraform could delete it in parallel with the workspace teardown - and since removing the DBFS root
  # CMK was a workspace *update* that re-validated [Get, Wrap, Unwrap], the destroy could fail partway through with
  # WorkspaceUpdateFailed. That grant now lives in the platform state, which a spoke destroy cannot touch.
  #
  # The DBFS root CMK is also no longer unset on destroy: azapi_update_resource performs no operation on delete, so the
  # workspace is deleted with the key still configured. A delete needs no vault access, so there is nothing left to race.
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

  # Access connectors can be placed in the platform's security resource group. Null keeps them in the workspace group.
  access_connector_resource_group_name = local.access_connector_resource_group_name

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
