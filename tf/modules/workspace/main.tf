locals {
  # Name of the workspace default storage account, created by Databricks in the managed resource group
  default_storage_name = join("", ["dbstorage", random_string.default_storage_naming.result])
  managed_rg_name      = join("", [module.naming.resource_group.name_unique, "adbmanaged"])
  public_subnet        = provider::azurerm::parse_resource_id(var.network_configuration.public_subnet_id)
  private_subnet       = provider::azurerm::parse_resource_id(var.network_configuration.private_subnet_id)
  csp_update_body = {
    properties = {
      enhancedSecurityCompliance = {
        complianceSecurityProfile = {
          complianceStandards = var.enhanced_security_compliance.compliance_security_profile_standards
        }
      }
    }
  }

  # The role granting wrap/unwrap on the shared vault's keys. Used by both CMK grants in dbfs_root_cmk.tf.
  cmk_role_definition_name = "Key Vault Crypto Service Encryption User"
}

module "naming" {
  source  = "Azure/naming/azurerm"
  version = "~>0.4"
  suffix  = [var.resource_suffix]
}

resource "random_string" "default_storage_naming" {
  special = false
  upper   = false
  length  = 13
}

# Define an Azure Databricks workspace resource
resource "azurerm_databricks_workspace" "this" {
  name                        = lookup(var.name_overrides, "databricks_workspace", module.naming.databricks_workspace.name)
  resource_group_name         = var.resource_group_name
  managed_resource_group_name = local.managed_rg_name
  location                    = var.location
  sku                         = "premium"

  # Auto-rotation for the managed disk key. The workspace API takes vault URI + key name + key *version*, so the
  # versioned key ID stays required; this flag tells the Disk Encryption Set to follow later versions on its own rather
  # than staying pinned to the version recorded here. Managed services CMK has no equivalent flag - rotating that key
  # requires an apply.
  #
  # Note: whether a GET returns the originally configured key version or the rotated-to version is not documented. If
  # it returns the latter, Terraform will see drift after a rotation and try to revert the version. If that happens,
  # add `ignore_changes = [managed_disk_cmk_key_vault_key_id]` rather than turning this flag off - reverting the version
  # is the wrong resolution. See the "Key versions" section of the README for how to verify.
  # Null rather than false when CMK is off: the provider requires this to be specified together with
  # managed_disk_cmk_key_vault_key_id, and false still counts as specified.
  managed_disk_cmk_rotation_to_latest_version_enabled = var.is_kms_enabled ? true : null

  managed_disk_cmk_key_vault_key_id     = var.is_kms_enabled ? var.managed_disk_key_id : null
  managed_services_cmk_key_vault_key_id = var.is_kms_enabled ? var.managed_services_key_id : null
  customer_managed_key_enabled          = var.is_kms_enabled
  infrastructure_encryption_enabled     = var.is_kms_enabled
  public_network_access_enabled         = !var.is_frontend_private_link_enabled
  network_security_group_rules_required = "NoAzureDatabricksRules"
  default_storage_firewall_enabled      = var.secure_workspace_default_storage
  access_connector_id                   = var.secure_workspace_default_storage ? azurerm_databricks_access_connector.default_storage[0].id : null

  enhanced_security_compliance {
    automatic_cluster_update_enabled      = var.enhanced_security_compliance.automatic_cluster_update_enabled
    compliance_security_profile_enabled   = var.enhanced_security_compliance.compliance_security_profile_enabled
    compliance_security_profile_standards = [] # Note that this is always an empty list, as a separate azapi resource manages this
    enhanced_security_monitoring_enabled  = var.enhanced_security_compliance.enhanced_security_monitoring_enabled
  }

  custom_parameters {
    storage_account_name                                 = local.default_storage_name
    no_public_ip                                         = true
    virtual_network_id                                   = var.network_configuration.virtual_network_id
    public_subnet_name                                   = local.public_subnet.resource_name
    private_subnet_name                                  = local.private_subnet.resource_name
    public_subnet_network_security_group_association_id  = var.network_configuration.public_subnet_network_security_group_association_id
    private_subnet_network_security_group_association_id = var.network_configuration.private_subnet_network_security_group_association_id
  }

  lifecycle {
    ignore_changes = [enhanced_security_compliance[0].compliance_security_profile_standards]
  }

  tags = var.tags
}

resource "azapi_update_resource" "this" {
  count       = var.enhanced_security_compliance.compliance_security_profile_standards == null ? 0 : 1
  type        = "Microsoft.Databricks/workspaces@2025-03-01-preview"
  resource_id = azurerm_databricks_workspace.this.id
  body        = local.csp_update_body
}

# Wait for 10 seconds after workspace creation to allow for APIs to become available
resource "time_sleep" "workspace_wait" {
  triggers = {
    workspace_id = azurerm_databricks_workspace.this.workspace_id
  }
  create_duration  = "10s"
  destroy_duration = "10s"
}

# Grant admin access to the provisioner account to the workspace, used for downstream workspace provider
resource "azurerm_role_assignment" "contributor" {
  role_definition_name = "contributor"
  scope                = azurerm_databricks_workspace.this.id
  principal_id         = var.provisioner_principal_id
  description          = "Granted by this Terraform configuration. It grants workspace admin to the provisioner principal of the workspace."
}

# This resource is used to output the workspace URL of the workspace AFTER the provisioner account has been granted admin
# This removes the need to use depends_on in downstream modules that use this workspace in their aliased provider.
resource "null_resource" "admin_wait" {
  triggers = {
    workspace_url = azurerm_databricks_workspace.this.workspace_url
    workspace_id  = azurerm_role_assignment.contributor.scope
    metastore_id  = databricks_metastore_assignment.this.metastore_id
  }
}

# Define a Databricks metastore assignment
resource "databricks_metastore_assignment" "this" {
  workspace_id = azurerm_databricks_workspace.this.workspace_id
  metastore_id = var.metastore_id
}

resource "databricks_mws_ncc_binding" "this" {
  network_connectivity_config_id = var.ncc_id
  workspace_id                   = azurerm_databricks_workspace.this.workspace_id
}

resource "databricks_workspace_network_option" "this" {
  network_policy_id = var.network_policy_id
  workspace_id      = azurerm_databricks_workspace.this.workspace_id
}
