output "tfstate_storage_account_name" {
  value       = azurerm_storage_account.tfstate.name
  description = "Storage account holding every layer's remote state in this subscription. Use in each layer's backend block."
}

output "tfstate_resource_group_name" {
  value       = local.bootstrap_rg.name
  description = "Resource group of the tfstate storage account. Use in each layer's backend block."
}

# Per-environment identity and resource-group coordinates. Feed these into the platform and spoke layers' var files
# (the resource groups) and into the Azure DevOps service connections' federated-credential verification (the client IDs
# are what the service connection authenticates as).
output "environments" {
  description = <<-EOT
    Per-environment bootstrap results. For each env:
      platform_identity_client_id  / workspace_identity_client_id  - the UAMI client (application) IDs the pipelines run as
      platform_identity_principal_id / workspace_identity_principal_id - the UAMI object IDs (for any manual RBAC)
      security_resource_group / spoke_resource_group - pass to the platform/spoke layers with create_*_resource_group = false
  EOT
  value = {
    for k, env in var.environments : k => {
      resource_suffix                 = env.resource_suffix
      security_resource_group         = azurerm_resource_group.security[k].name
      spoke_resource_group            = azurerm_resource_group.spoke[k].name
      platform_identity_client_id     = azurerm_user_assigned_identity.platform[k].client_id
      platform_identity_principal_id  = azurerm_user_assigned_identity.platform[k].principal_id
      workspace_identity_client_id    = azurerm_user_assigned_identity.workspace[k].client_id
      workspace_identity_principal_id = azurerm_user_assigned_identity.workspace[k].principal_id
    }
  }
}

# GitHub Actions wiring, emitted only when var.github_repository is set. One entry per GitHub Environment the demo
# workflow uses (<env>-platform / <env>-workspace). Each carries the ARM_CLIENT_ID to set as an Environment variable and
# the exact federated-credential subject, so configuring the GitHub Environments is a copy-paste from this output.
output "github_environments" {
  description = "Map of GitHub Environment name -> { client_id, subject, tenant_id }. Empty when github_repository is null. client_id is the UAMI to set as ARM_CLIENT_ID on that Environment; subject is the federated-credential subject GitHub must present."
  value = var.github_repository == null ? {} : merge(
    {
      for k, env in var.environments : "${k}-platform" => {
        client_id = azurerm_user_assigned_identity.platform[k].client_id
        subject   = "repo:${var.github_repository}:environment:${k}-platform"
        tenant_id = azurerm_user_assigned_identity.platform[k].tenant_id
      }
    },
    {
      for k, env in var.environments : "${k}-workspace" => {
        client_id = azurerm_user_assigned_identity.workspace[k].client_id
        subject   = "repo:${var.github_repository}:environment:${k}-workspace"
        tenant_id = azurerm_user_assigned_identity.workspace[k].tenant_id
      }
    }
  )
}
