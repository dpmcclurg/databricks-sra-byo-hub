# Customer-managed key wiring that can only happen after the workspace exists.
#
# Managed services and managed disk CMK are attributes on azurerm_databricks_workspace (see main.tf) because they are set
# at create time. The two grants below and the DBFS root key cannot be: they reference identities that Azure creates
# *with* the workspace, so they do not exist until it has been built.
#
# The vault is the shared platform vault from tf/platform. This module never creates or modifies it beyond granting
# wrap/unwrap to the two identities it owns.

# The workspace storage account identity wraps and unwraps both the DBFS root key and the managed services key. Azure
# Databricks documents the managed services grant as needing two principals - the AzureDatabricks enterprise application
# and this storage identity. The former is granted once by the platform layer; this is the latter.
resource "azurerm_role_assignment" "workspace_storage_cmk" {
  count = var.is_kms_enabled ? 1 : 0

  scope                = var.key_vault_id
  role_definition_name = local.cmk_role_definition_name
  principal_id         = azurerm_databricks_workspace.this.storage_account_identity[0].principal_id

  # Skips a Microsoft Graph lookup to infer the principal type, which is itself eventually consistent for an identity
  # this new and is a needless second source of flakiness.
  principal_type = "ServicePrincipal"

  description = "Granted by this Terraform configuration so the workspace storage account can wrap/unwrap the DBFS root and managed services CMKs."
}

# The managed disk identity is the system-assigned identity of the Disk Encryption Set that Azure creates in the
# workspace's managed resource group. The Azure Databricks documentation describes granting "the Disk Encryption Set" in
# its portal walkthrough and "the managed disk identity" in its CLI walkthrough - these are the same principal, and
# reading it off the workspace avoids a data source against the managed resource group, which carries deny assignments.
resource "azurerm_role_assignment" "managed_disk_cmk" {
  count = var.is_kms_enabled ? 1 : 0

  scope                = var.key_vault_id
  role_definition_name = local.cmk_role_definition_name
  principal_id         = azurerm_databricks_workspace.this.managed_disk_identity[0].principal_id
  principal_type       = "ServicePrincipal"

  description = "Granted by this Terraform configuration so the Disk Encryption Set can wrap/unwrap the managed disk CMK."
}

# CMK for the workspace storage account (DBFS root).
#
# This scope covers the whole workspace storage account, not just DBFS root paths. Azure Databricks documents it as also
# covering job results, Databricks SQL results, MLflow models, notebook revisions and other workspace system data, and
# FileStore. See https://learn.microsoft.com/en-us/azure/databricks/security/keys/customer-managed-keys
#
# WHY azapi RATHER THAN azurerm_databricks_workspace_root_dbfs_customer_managed_key
#
# Setting this key makes Databricks re-validate get/wrap/unwrap against the vault. Azure RBAC is eventually consistent and
# Key Vault caches authorization decisions - the RBAC guide says to "allow several minutes for role assignments to
# refresh" - so azurerm_role_assignment returning does not mean the vault honours the grant yet. depends_on orders the
# operations but cannot wait for propagation, so this step intermittently fails with a permission error that reads like a
# misconfigured grant rather than a race:
#
#   WorkspaceUpdateFailed: Invalid permissions on the specified KeyVault ... does not have keys get permission
#
# The azurerm resource exposes only `timeouts`, which does not help: the call fails fast rather than hanging. azapi
# exposes `retry`, keyed on the error message, so this retries until the grant actually lands. That is a wait on the real
# condition instead of a fixed sleep sized by guesswork - it returns as soon as the grant propagates, and it still fails
# the apply if the grant is genuinely wrong.
#
# This follows Microsoft's provider guidance, which is to stay AzureRM-primary and use azapi_update_resource for
# properties AzureRM does not expose. It is also the established pattern here - see azapi_update_resource.this in main.tf
# for the compliance security profile, and modules/self-approving-pe.
#
# Two consequences, both deliberate:
#
#   1. azapi_update_resource performs NO operation on delete. The DBFS root key is therefore not unset before the
#      workspace is deleted. That is desirable: unsetting it was a workspace *update* that re-validated against the vault,
#      and it is what made destroys fail partway through when the vault grants had already gone. A delete needs no vault
#      access. Do not "fix" the missing delete.
#   2. The body is hand-written, so property casing matters and ARM is inconsistent here. Verified against a deployed
#      workspace in tests/cmk_configured: the read path is properties.parameters.encryption.value with keySource and
#      keyvaulturi (lowercase v, not camel case). A mistyped property can be silently ignored, leaving DBFS root on the
#      platform-managed key while Terraform reports success - which is why the cmk_configured integration assertion, which
#      reads keySource per scope, must stay.
resource "azapi_update_resource" "dbfs_root_cmk" {
  count = var.is_kms_enabled ? 1 : 0

  type        = "Microsoft.Databricks/workspaces@2024-05-01"
  resource_id = azurerm_databricks_workspace.this.id

  body = {
    properties = {
      parameters = {
        encryption = {
          value = {
            keySource   = "Microsoft.Keyvault"
            keyvaulturi = var.key_vault_uri
            KeyName     = var.dbfs_root_key_name
            keyversion  = var.dbfs_root_key_version
          }
        }
      }
    }
  }

  # Matches only the permission/propagation errors. Do NOT broaden this: a catch-all would turn a genuinely wrong grant -
  # wrong principal, missing role, wrong vault - into a slow timeout instead of a fast, clear failure. If this window is
  # being exhausted regularly, the grant is wrong; raising the interval only hides it.
  retry = {
    error_message_regex = [
      "Invalid permissions on the specified KeyVault",
      "WorkspaceUpdateFailed",
      "KeyVaultAccessForbidden",
    ]
    interval_seconds     = 15
    max_interval_seconds = 120
  }

  timeouts {
    update = "30m"
  }

  # retry handles the timing; ordering still has to be declared. Both grants must be in place before Databricks
  # re-validates, and the storage identity's grant is the one it actually checks here.
  depends_on = [
    azurerm_role_assignment.workspace_storage_cmk,
    azurerm_role_assignment.managed_disk_cmk,
  ]
}
