terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=3.65.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">=2.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = ">=1.24.1"
      # Account-admin operations run only under this explicit alias (least-privilege-by-default: the default databricks
      # provider is the workspace UAMI). The caller must map databricks.account; this module has no unqualified databricks
      # resource, so it never uses a default databricks provider.
      configuration_aliases = [databricks.account]
    }
    null = {
      source  = "hashicorp/null"
      version = ">=3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">=0.13"
    }
    random = {
      source  = "hashicorp/random"
      version = ">=3.0"
    }
  }
  required_version = ">=1.9.8"
}
