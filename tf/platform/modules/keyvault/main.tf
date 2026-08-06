# Shared Key Vault and customer-managed keys for the Azure Databricks workspaces in this subscription and region.
#
# This vault is a platform asset, not a workspace asset: it is created once and shared by every spoke workspace
# deployment, and it outlives all of them. Spokes consume it as an input and never modify it, apart from granting their
# own workspace identities wrap/unwrap - see modules/workspace in the spoke configuration.
#
# Region and tenant are constrained by the platform, not by preference: Azure Databricks requires the vault to be in the
# same region and Microsoft Entra ID tenant as every workspace it serves. A different subscription is allowed, a
# different region is not. So this configuration is per subscription *per region* - see var.location.
#
# Azure Databricks documents lost keys as unrecoverable: if a key is lost or revoked and cannot be restored, the
# workspace's compute resources stop working. With one vault shared across workspaces that blast radius is fleet-wide,
# which is why purge protection is on, prevent_destroy is set here and on all three keys, and the platform state belongs
# in a versioned remote backend.
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "~>0.4"
  suffix  = [var.resource_suffix]
}

resource "azurerm_key_vault" "this" {
  # Prefer an explicit, deterministic name over naming.key_vault.name_unique. name_unique embeds a random suffix, which
  # is the right default for a disposable per-workspace vault but the wrong one for a shared singleton: losing or
  # re-initialising this state would generate a *new* name, producing a second empty vault while every spoke still points
  # at the old one's key URIs. Orphaned but alive, so nothing fails loudly. A fixed name plus
  # recover_soft_deleted_key_vaults means a re-apply recovers the existing vault instead.
  name                = coalesce(var.key_vault_name, module.naming.key_vault.name_unique)
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id

  sku_name = "premium"

  # Azure RBAC instead of access policies. See rbac.tf for why, and for the role assignments.
  rbac_authorization_enabled = true

  # Purge protection cannot be disabled once enabled. Enabled here because a purged key is unrecoverable and would
  # permanently break the compute of every workspace using this vault. Note that this also means the vault stays
  # soft-deleted for soft_delete_retention_days after a destroy, and the name stays reserved - see the teardown section
  # of the platform README.
  purge_protection_enabled   = true
  soft_delete_retention_days = var.soft_delete_retention_days

  # No public data-plane access. In-VNet clients reach the vault over a private endpoint created by each spoke; the keys
  # themselves are created through ARM, which is a control-plane operation and so is not subject to the vault firewall.
  public_network_access_enabled = false

  network_acls {
    # Deny by default, so only the bypass below reaches the vault.
    default_action = "Deny"

    # Required for customer-managed keys to work at all. Neither CMK unwrap call reaches the vault through a private
    # endpoint: managed services keys are unwrapped by the Databricks control plane, and managed disk keys by the Disk
    # Encryption Set in the workspace's managed resource group. Both are outside every spoke VNet. Azure Databricks and
    # Azure Disk Storage are Key Vault trusted services, and the bypass still applies when public access is disabled,
    # which is what admits them.
    #
    # The Disk Encryption Set is why this cannot be replaced by an IP allowlist: it has no published IP range. The
    # control plane does publish NAT ranges, but allowlisting only those would leave managed disk CMK broken, so the
    # bypass is required either way and an allowlist would add nothing.
    #
    # An NCC private endpoint rule does not replace this either. Key Vault is a supported NCC resource type, so
    # serverless compute can reach a vault privately - a Key Vault-backed secret scope, say - but NCC only covers
    # serverless compute egress, and neither CMK caller is serverless compute.
    #
    # Do not set this vault to "Secured by Perimeter" (a Network Security Perimeter in enforced mode): enforced mode
    # overrides the trusted-services bypass and breaks CMK for both key types, for every workspace at once.
    #
    # Removing this bypass breaks CMK: clusters fail to start with KeyVaultAccessForbidden.
    bypass = "AzureServices"
  }

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}
