terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>4.9"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~>1.81"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~>2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~>3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~>0.13"
    }
  }
  required_version = "~>1.11"

  # Remote state is optional for a disposable spoke, but recommended once a spoke is run from CI so applies lock and the
  # state is durable. Left commented so local runs use local state with zero config (Option A in tf/bootstrap/README.md).
  # Enable the same way as the platform layer: CI drops a backend_override.tf and runs
  # `terraform init -backend-config=<env>.backend.hcl`; the storage account/container come from tf/bootstrap and the key
  # is per spoke (e.g. spoke-<suffix>.tfstate).
  #
  # backend "azurerm" {
  #   use_azuread_auth = true
  #   # resource_group_name / storage_account_name / container_name / key supplied via -backend-config
  # }
}
