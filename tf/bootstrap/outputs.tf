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
