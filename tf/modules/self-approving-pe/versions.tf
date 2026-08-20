terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = ">=1.24.1"
      # Only STEP 1 of the chain (databricks_mws_ncc_private_endpoint_rule) is account-admin-gated and uses this alias.
      # STEPS 2-3 (the azapi read + approval) run as the workspace UAMI. The caller must map databricks.account.
      configuration_aliases = [databricks.account]
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">=2.0"
    }
  }
  required_version = ">=1.9.8"
}
