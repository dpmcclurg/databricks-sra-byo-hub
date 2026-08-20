terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = ">=1.0"
      # databricks.workspace: catalog resources (UC storage credential, external location, catalog) run as the workspace
      # UAMI. databricks.account: the nested self-approving-pe module's NCC private endpoint rule needs account admin.
      configuration_aliases = [databricks.workspace, databricks.account]
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=3.0"
    }
  }
  required_version = ">=1.0"
}
