# Key Vault and customer-managed keys for the spoke workspace. Created only when cmk_enabled is true and
# cmk_source is "create"; see the root variables for the "existing" alternative.
#
# The vault lives in the spoke rather than the hub. Azure Databricks requires the vault to be in the same region and
# tenant as the workspace it serves - it may be in a different subscription, but not a different region - so a single hub
# vault cannot serve spokes in more than one region. Keeping it in the spoke also scopes a bad rotation or an over-broad
# access policy edit to one environment, and avoids several deployments mutating one vault's access policies from
# separate Terraform states.
#
# Azure Databricks documents that lost keys are not recoverable: if a key is lost or revoked and cannot be restored, the
# workspace's compute resources stop working. Purge protection is enabled below to make accidental deletion harder.
#
# Three keys are created, one per workspace CMK scope: managed services (control plane), DBFS root (workspace storage
# account), and managed disks (classic compute data disks). Separate keys rather than one shared key, so that each can be
# rotated or revoked without affecting the others.
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

  # Purge protection cannot be disabled once enabled. Enabled here because a purged key is unrecoverable and would
  # permanently break the workspace's compute. Note that this also means the vault stays soft-deleted for
  # soft_delete_retention_days after a destroy - see the teardown section of the README.
  purge_protection_enabled   = true
  soft_delete_retention_days = var.soft_delete_retention_days

  # No public data-plane access. In-VNet clients reach the vault over the private endpoint below; the keys themselves
  # are created through ARM, which is a control-plane operation and so is not subject to the vault firewall.
  public_network_access_enabled = false

  network_acls {
    # Deny by default, so only the bypass below reaches the vault.
    default_action = "Deny"

    # Required for customer-managed keys to work at all. Neither CMK unwrap call reaches the vault through the
    # private endpoint below: managed services keys are unwrapped by the Databricks control plane, and managed disk
    # keys by the Disk Encryption Set in the workspace's managed resource group. Both are outside this VNet. Azure
    # Databricks and Azure Disk Storage are Key Vault trusted services, and the bypass still applies when public
    # access is disabled, which is what admits them.
    #
    # The Disk Encryption Set is why this cannot be replaced by an IP allowlist: it has no published IP range. The
    # control plane does publish NAT ranges, but allowlisting only those would leave managed disk CMK broken, so the
    # bypass is required either way and an allowlist would add nothing.
    #
    # An NCC private endpoint rule does not replace this either. Key Vault is a supported NCC resource type, so
    # serverless compute can reach a vault privately - a Key Vault-backed secret scope, say - but NCC only covers
    # serverless compute egress, and neither CMK caller is serverless compute.
    #
    # Removing this bypass breaks CMK: clusters fail to start with KeyVaultAccessForbidden.
    bypass = "AzureServices"
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

# The keys are created through ARM (Microsoft.KeyVault/vaults/keys) rather than with azurerm_key_vault_key.
#
# azurerm_key_vault_key calls the Key Vault *data plane* (<vault>.vault.azure.net), which the vault firewall governs.
# With public network access disabled that call fails with 403 from anywhere outside the spoke, so Terraform could not
# create the keys without an IP exception. ARM key creation is a *control-plane* operation against
# management.azure.com, and per the Key Vault networking docs, "Key Vault firewall rules only apply to data plane
# operations. Control plane operations are not subject to the restrictions specified in firewall rules."
#
# This keeps the vault fully closed to the public internet with no allowlist. The tradeoff is that ARM key resources do
# not expose a versioned key ID directly, so the version is read out of the response below.
#
# One consequence of using ARM: it lowercases tag *names* on this resource type, so a tag supplied as "Owner" is stored
# as "owner" and read back that way. The root module lowercases tag names before passing them in, so config matches
# what is stored and the keys converge. Without that, a tag diff here makes `output` unknown, which propagates to the
# versioned key IDs read out of it - so the workspace's CMK attributes become "known after apply" and every apply pushes
# the workspace back into the "Updating" state that the private endpoints race against.
locals {
  key_ops = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  key_body = {
    properties = {
      kty     = "RSA"
      keySize = 2048
      keyOps  = local.key_ops
    }
  }
}

resource "azapi_resource" "managed_services_key" {
  type      = "Microsoft.KeyVault/vaults/keys@2023-07-01"
  parent_id = azurerm_key_vault.this.id
  name      = "${module.naming.key_vault_key.name}-adb-services"

  body = local.key_body
  tags = var.tags

  response_export_values = ["properties.keyUriWithVersion"]

  depends_on = [azurerm_key_vault_access_policy.provisioner]
}

resource "azapi_resource" "dbfs_root_key" {
  type      = "Microsoft.KeyVault/vaults/keys@2023-07-01"
  parent_id = azurerm_key_vault.this.id
  name      = "${module.naming.key_vault_key.name}-adb-dbfs"

  body = local.key_body
  tags = var.tags

  response_export_values = ["properties.keyUriWithVersion"]

  depends_on = [azurerm_key_vault_access_policy.provisioner]
}

resource "azapi_resource" "managed_disk_key" {
  type      = "Microsoft.KeyVault/vaults/keys@2023-07-01"
  parent_id = azurerm_key_vault.this.id
  name      = "${module.naming.key_vault_key.name}-adb-disk"

  body = local.key_body
  tags = var.tags

  response_export_values = ["properties.keyUriWithVersion"]

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
