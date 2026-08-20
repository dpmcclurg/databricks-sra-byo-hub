# Role assignments for the two per-environment UAMIs. Made here, by the foundational identity (which holds RBAC
# Administrator on the subscription), so the child identities arrive fully entitled to run their layers. Scoped as
# tightly as each layer's actual resource writes allow - see the README's RBAC tables for the rationale behind each.

# =====================================================================================================================
# Platform UAMI grants
# =====================================================================================================================

# Create the vault, private endpoint, and DNS zone in the security RG. Contributor rather than a narrower role because
# the platform layer creates several resource types (vault, private endpoint, private DNS zone, VNet links).
resource "azurerm_role_assignment" "platform_rg_contributor" {
  for_each = var.environments

  scope                = azurerm_resource_group.security[each.key].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.platform[each.key].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Platform UAMI provisions the shared Key Vault and its private access in this security RG."
}

# The platform layer creates the CMK keys through ARM (control-plane) and grants the Azure Databricks enterprise app the
# Crypto Service Encryption User role on the vault. Granting a role requires RBAC write, delegated here scoped to the RG
# so the platform UAMI can make that assignment without holding subscription-wide RBAC rights.
resource "azurerm_role_assignment" "platform_rbac_admin" {
  for_each = var.environments

  scope                = azurerm_resource_group.security[each.key].id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.platform[each.key].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Platform UAMI grants the Azure Databricks control plane the CMK Crypto role on the vault (see platform rbac.tf)."
}

# Read/write this env's Terraform state blob. Storage uses AAD auth (no shared key), so the data-plane role is required.
resource "azurerm_role_assignment" "platform_tfstate" {
  for_each = var.environments

  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.platform[each.key].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Platform UAMI reads/writes the platform layer's remote state."
}

# =====================================================================================================================
# Workspace UAMI grants
# =====================================================================================================================

# Create the workspace, VNet, subnets, private endpoints, and catalog in the spoke RG.
resource "azurerm_role_assignment" "workspace_rg_contributor" {
  for_each = var.environments

  scope                = azurerm_resource_group.spoke[each.key].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.workspace[each.key].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Workspace UAMI provisions the spoke workspace, VNet, and catalog in this RG."
}

# The spoke grants its provisioner principal (this UAMI) workspace-admin Contributor on the created workspace, and grants
# the workspace's storage + Disk Encryption Set identities the CMK role on the platform vault. Both are role writes, so
# the workspace UAMI needs RBAC write in the spoke RG.
resource "azurerm_role_assignment" "workspace_rbac_admin" {
  for_each = var.environments

  scope                = azurerm_resource_group.spoke[each.key].id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.workspace[each.key].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Workspace UAMI self-grants workspace Contributor and grants its workspace identities the CMK role (see spoke workspace module)."
}

# Cross-layer grant: the workspace layer grants its workspace-storage identity and Disk Encryption Set identity the CMK
# role ON THE PLATFORM VAULT. That is a role write scoped to the vault's resource group (the security RG), so the
# workspace UAMI needs RBAC write there too - the one place a workspace identity reaches across into platform-owned
# resources. Key Vault Data Access Administrator is the least-privilege role that can delegate the Key Vault Crypto
# roles, and it cannot grant itself broader vault rights.
resource "azurerm_role_assignment" "workspace_vault_data_access_admin" {
  for_each = var.environments

  scope                = azurerm_resource_group.security[each.key].id
  role_definition_name = "Key Vault Data Access Administrator"
  principal_id         = azurerm_user_assigned_identity.workspace[each.key].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Workspace UAMI grants its workspace-storage and Disk Encryption Set identities the CMK Crypto role on the shared platform vault."
}

# Approve the private endpoints the spoke creates to the workspace DEFAULT STORAGE account (dfs + blob sub-resources),
# which is required when secure_workspace_default_storage is on. That account lives in the Databricks-MANAGED resource
# group, and auto-approving a private endpoint needs
# Microsoft.Storage/storageAccounts/PrivateEndpointConnectionsApproval/action on the target account - a linked-scope
# check the workspace UAMI's spoke-RG Contributor does not satisfy, so PE creation fails with LinkedAuthorizationFailed.
#
# The managed RG's name is generated by Azure and not known until the workspace exists, so this cannot be scoped to that
# RG at bootstrap time. Rather than grant a broad built-in role (Storage Account Contributor) subscription-wide, define a
# CUSTOM role carrying only the four storage private-endpoint actions and assign THAT at subscription scope. The UAMI can
# approve storage private endpoints anywhere in the subscription but can do nothing else to storage - no data access, no
# key management, no account create/delete. The managed RG's deny assignment permits these actions (they are in its
# notActions), so the grant takes effect there.
resource "azurerm_role_definition" "workspace_storage_pe_approver" {
  name        = "Databricks Workspace Storage PE Approver (${data.azurerm_subscription.current.subscription_id})"
  scope       = data.azurerm_subscription.current.id
  description = "Approve private endpoint connections on storage accounts (for the Databricks workspace default storage in the managed RG). Least-privilege alternative to Storage Account Contributor."

  permissions {
    actions = [
      "Microsoft.Storage/storageAccounts/read",
      "Microsoft.Storage/storageAccounts/privateEndpointConnections/read",
      "Microsoft.Storage/storageAccounts/privateEndpointConnections/write",
      "Microsoft.Storage/storageAccounts/PrivateEndpointConnectionsApproval/action",
    ]
    not_actions = []
  }

  assignable_scopes = [data.azurerm_subscription.current.id]
}

resource "azurerm_role_assignment" "workspace_storage_pe_approver" {
  for_each = var.environments

  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.workspace_storage_pe_approver.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.workspace[each.key].principal_id
  principal_type     = "ServicePrincipal"
  description        = "Workspace UAMI approves the private endpoints to the workspace default storage account in the Databricks-managed RG."
}

# Spoke-side VNet peering to the hub. Network Contributor plus the peer/action carried by it lets the workspace UAMI
# create the spoke half of the peering. One grant per hub VNet the env uses (hub differs by region and prod/non-prod).
# When an env sets create_hub_peering = false, its hub_virtual_network_ids is empty and no grant is made.
resource "azurerm_role_assignment" "workspace_hub_peering" {
  for_each = local.workspace_hub_peering_grants

  scope                = each.value.hub_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.workspace[each.value.env_key].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Workspace UAMI creates the spoke half of the VNet peering against this hub."
}

# Read/write this env's Terraform state blob.
resource "azurerm_role_assignment" "workspace_tfstate" {
  for_each = var.environments

  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.workspace[each.key].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Workspace UAMI reads/writes the spoke layer's remote state."
}

# NOTE: the account-admin UAMI gets no Azure RBAC here. It needs the built-in Reader role at SUBSCRIPTION scope so it can
# be used through an Azure DevOps service connection (the connection's verification and the AzureCLI@2 `az login` both
# require subscription read), but that is granted MANUALLY as a post-bootstrap step - alongside adding the SP to the
# Databricks account `admins` group - not managed here. See the Account Admin Split spec's post-bootstrap steps.
