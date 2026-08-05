# Key Vault and customer-managed keys for the spoke workspace.
#
# The vault lives in the spoke rather than the hub. A vault must be in the same region and tenant as the workspace it
# serves - it may be in a different subscription, but not a different region - so a single hub vault cannot serve spokes
# in more than one region. Keeping it in the spoke also scopes the blast radius of a bad rotation or an over-broad
# access policy edit to one environment, and avoids several deployments mutating one vault's access policies from
# separate Terraform states.
#
# Note that lost keys are not recoverable: if a key is lost or revoked and cannot be restored, the workspace's compute
# resources stop working. Purge protection is enabled to make accidental deletion harder.
#
# Two keys are created, matching the two workspace CMK scopes: managed services and managed disks. DBFS root CMK is
# intentionally not configured - see the README.
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "~>0.4"
  suffix  = [var.resource_suffix]
}

# Object ID of the Azure Databricks service principal, which needs wrap/unwrap on the keys
data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "databricks" {
  client_id = data.azuread_application_published_app_ids.well_known.result["AzureDataBricks"]
}

resource "azurerm_key_vault" "this" {
  name                = module.naming.key_vault.name_unique
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id

  sku_name = "premium"

  # Purge protection cannot be disabled once enabled. It is required here because a purged key is unrecoverable and
  # would permanently break the workspace's compute.
  purge_protection_enabled   = true
  soft_delete_retention_days = var.soft_delete_retention_days

  # Reached over a private endpoint from the spoke
  public_network_access_enabled = false

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
  }

  tags = var.tags
}

# Key management permissions for the principal running Terraform, required to create the keys below
resource "azurerm_key_vault_access_policy" "provisioner" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = var.tenant_id
  object_id    = var.provisioner_principal_id

  key_permissions = [
    "Get",
    "List",
    "Create",
    "Decrypt",
    "Encrypt",
    "Sign",
    "UnwrapKey",
    "Verify",
    "WrapKey",
    "Delete",
    "Restore",
    "Recover",
    "Update",
    "Purge",
    "GetRotationPolicy",
  ]
}

# The Azure Databricks service principal wraps and unwraps the keys on the workspace's behalf
resource "azurerm_key_vault_access_policy" "databricks" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = var.tenant_id
  object_id    = data.azuread_service_principal.databricks.object_id

  key_permissions = [
    "Get",
    "UnwrapKey",
    "WrapKey",
  ]
}

resource "azurerm_key_vault_key" "managed_services" {
  name         = "${module.naming.key_vault_key.name}-adb-services"
  key_vault_id = azurerm_key_vault.this.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  tags = var.tags

  depends_on = [azurerm_key_vault_access_policy.provisioner]
}

resource "azurerm_key_vault_key" "managed_disk" {
  name         = "${module.naming.key_vault_key.name}-adb-disk"
  key_vault_id = azurerm_key_vault.this.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  tags = var.tags

  depends_on = [azurerm_key_vault_access_policy.provisioner]
}

# Private connectivity to the vault, in the spoke's privatelink subnet
resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name

  tags = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                  = "${var.resource_suffix}-keyvault-vnetlink"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
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
    private_connection_resource_id = azurerm_key_vault.this.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "keyvault"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }

  tags = var.tags
}
