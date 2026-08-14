provider "azurerm" {
  features {}
  subscription_id = var.subscription_id

  # use_oidc lets the workspace UAMI authenticate via the Azure DevOps Workload Identity Federation service connection
  # when this layer runs from a pipeline (the AzureCLI@2 task exports ARM_USE_OIDC / ARM_OIDC_TOKEN / ARM_CLIENT_ID /
  # ARM_TENANT_ID). Harmless for a local `az login` run, which uses the CLI credential instead. See tf/bootstrap/README.md.
  use_oidc = var.use_oidc
}

provider "azapi" {
  subscription_id = var.subscription_id
  use_oidc        = var.use_oidc
}

provider "databricks" {
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
}

# Spoke provider (required for creating a catalog in the spoke workspace)
provider "databricks" {
  alias = "spoke"
  host  = module.spoke_workspace.workspace_url
}

# These blocks are not required by terraform, but they are here to silence TFLint warnings
provider "null" {}

provider "time" {}
