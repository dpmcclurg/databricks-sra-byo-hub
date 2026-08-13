provider "azurerm" {
  features {}
  subscription_id = var.subscription_id

  # use_oidc lets the foundational UAMI authenticate via the Azure DevOps Workload Identity Federation service
  # connection when this layer is run from a pipeline (the AzureCLI@2 task exports ARM_USE_OIDC / ARM_OIDC_TOKEN /
  # ARM_CLIENT_ID / ARM_TENANT_ID). It is harmless for a local `az login` run, which uses the CLI credential instead.
  use_oidc = var.use_oidc
}
