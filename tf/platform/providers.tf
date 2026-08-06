provider "azurerm" {
  subscription_id = var.subscription_id

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
}

# Used only to resolve the AzureDatabricks enterprise application's object ID. No Azure RBAC involved; this needs
# directory read permission in Entra, which is separate from the subscription roles.
provider "azuread" {}
