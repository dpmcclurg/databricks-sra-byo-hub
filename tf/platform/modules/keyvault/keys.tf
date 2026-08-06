# The keys are created through ARM (Microsoft.KeyVault/vaults/keys) rather than with azurerm_key_vault_key.
#
# azurerm_key_vault_key calls the Key Vault *data plane* (<vault>.vault.azure.net), which the vault firewall governs.
# With public network access disabled that call fails with 403 from anywhere outside the VNet, so Terraform could not
# create the keys without an IP exception. ARM key creation is a *control-plane* operation against
# management.azure.com, and per the Key Vault networking docs, "Key Vault firewall rules only apply to data plane
# operations. Control plane operations are not subject to the restrictions specified in firewall rules."
#
# The same asymmetry is why this works with rbac_authorization_enabled: Microsoft.KeyVault/vaults/keys/write is a
# control-plane Action, carried by Key Vault Contributor (Microsoft.KeyVault/*), which has no DataActions at all. So the
# principal running this needs no data-plane role, no access policy, and no firewall exception.
#
# This keeps the vault fully closed to the public internet with no allowlist. Two tradeoffs:
#
#   - ARM key resources do not expose a versioned key ID directly, so the version is read out of the response below.
#   - vaults/keys/write "does not create subsequent versions, and does not update existing keys", so this can create
#     keys but cannot rotate them. Rotation is a data-plane operation and is therefore out-of-band - see the rotation
#     runbook in the platform README.
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

  key_prefix = coalesce(var.key_name_prefix, module.naming.key_vault_key.name)
}

# One key per workspace CMK scope, shared by every spoke bound to this vault. Separate keys rather than one shared key,
# so that each scope can be rotated or revoked without affecting the others.
#
# prevent_destroy is deliberate: these are shared platform keys, and Azure Databricks documents lost keys as
# unrecoverable. Removing them breaks every workspace using this vault. Taking one out requires editing this file.
resource "azapi_resource" "managed_services_key" {
  type      = "Microsoft.KeyVault/vaults/keys@2023-07-01"
  parent_id = azurerm_key_vault.this.id
  name      = "${local.key_prefix}-adb-services"

  body = local.key_body
  tags = var.tags

  response_export_values = ["properties.keyUriWithVersion"]

  lifecycle {
    prevent_destroy = true
  }
}

resource "azapi_resource" "dbfs_root_key" {
  type      = "Microsoft.KeyVault/vaults/keys@2023-07-01"
  parent_id = azurerm_key_vault.this.id
  name      = "${local.key_prefix}-adb-dbfs"

  body = local.key_body
  tags = var.tags

  response_export_values = ["properties.keyUriWithVersion"]

  lifecycle {
    prevent_destroy = true
  }
}

resource "azapi_resource" "managed_disk_key" {
  type      = "Microsoft.KeyVault/vaults/keys@2023-07-01"
  parent_id = azurerm_key_vault.this.id
  name      = "${local.key_prefix}-adb-disk"

  body = local.key_body
  tags = var.tags

  response_export_values = ["properties.keyUriWithVersion"]

  lifecycle {
    prevent_destroy = true
  }
}
