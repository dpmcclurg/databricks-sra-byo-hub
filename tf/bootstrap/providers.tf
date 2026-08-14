provider "azurerm" {
  features {}
  subscription_id = var.subscription_id

  # use_oidc lets the foundational UAMI authenticate via the Azure DevOps Workload Identity Federation service
  # connection when this layer is run from a pipeline (the AzureCLI@2 task exports ARM_USE_OIDC / ARM_OIDC_TOKEN /
  # ARM_CLIENT_ID / ARM_TENANT_ID). It is harmless for a local `az login` run, which uses the CLI credential instead.
  use_oidc = var.use_oidc

  # The tfstate storage account sets shared_access_key_enabled = false (AAD-only), so the provider must use the caller's
  # AAD identity for storage DATA-plane calls (creating the blob container, the post-create Blob Service probe). Without
  # this the provider falls back to shared-key auth and fails with "Key based authentication is not permitted on this
  # storage account". The caller (you locally, or the foundational UAMI in CI) needs Storage Blob Data Contributor /
  # Owner on the account - see the README.
  storage_use_azuread = true
}
