provider "azurerm" {
  subscription_id = var.subscription_id

  # use_oidc lets the platform UAMI authenticate via the Azure DevOps Workload Identity Federation service connection
  # when this layer runs from a pipeline. Harmless for a local `az login` run. See tf/bootstrap/README.md.
  use_oidc = var.use_oidc

  features {
    key_vault {
      # Purge protection is enabled on the vault and cannot be turned off, so these two would fail anyway. Set
      # explicitly so the intent is not mistaken for an oversight: a destroy leaves the vault and keys soft-deleted, and
      # reclaiming the name early requires an explicit, irreversible `az keyvault purge`.
      purge_soft_delete_on_destroy       = false
      purge_soft_deleted_keys_on_destroy = false

      # The highest-value line in this file. Paired with an explicit key_vault_name, an accidental destroy followed by a
      # re-apply *recovers* the soft-deleted vault - keys and all - instead of failing on a name that Azure has reserved
      # for the retention window. This is the azurerm default; it is set here so it cannot drift silently.
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
  use_oidc        = var.use_oidc
}

# Used only to resolve the AzureDatabricks enterprise application's object ID. No Azure RBAC involved; this needs
# directory read permission in Entra, which is separate from the subscription roles.
#
# Note: a UAMI cannot be granted Microsoft Graph directory-read the way an app registration can, so when this layer runs
# as the platform UAMI in CI, set databricks_service_principal_object_id explicitly to skip this lookup entirely. See
# tf/bootstrap/README.md.
provider "azuread" {
  use_oidc = var.use_oidc
}
