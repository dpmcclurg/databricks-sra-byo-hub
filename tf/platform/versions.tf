terraform {
  required_providers {
    # rbac_authorization_enabled requires >=4.29
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>4.29"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~>2.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~>3.0"
    }
  }
  required_version = "~>1.11"

  # This state describes a shared, long-lived asset whose name is recoverable only from configuration and state. A local
  # state file is acceptable for a disposable spoke; it is not acceptable here. Configure a versioned, locking remote
  # backend before the first real apply.
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstate"
  #   container_name       = "tfstate"
  #   key                  = "databricks-platform-prod-<region>.tfstate"
  #   use_azuread_auth     = true
  # }
}
