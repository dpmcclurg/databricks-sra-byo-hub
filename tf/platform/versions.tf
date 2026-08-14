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
  # Left commented so the repo works out-of-box locally (local state, zero config - good for throwaway testing per
  # Option A in tf/bootstrap/README.md). Two ways to enable the remote backend:
  #   - CI: the pipeline drops a backend_override.tf and runs `terraform init -backend-config=<env>.backend.hcl`.
  #   - Local (sharing remote state): copy backend.hcl.example to <env>.backend.hcl, uncomment the block below, and
  #     `terraform init -backend-config=<env>.backend.hcl`.
  # The storage account and container are created by tf/bootstrap; the state key is per environment.
  #
  # backend "azurerm" {
  #   use_azuread_auth = true
  #   # resource_group_name / storage_account_name / container_name / key supplied via -backend-config
  # }
}
