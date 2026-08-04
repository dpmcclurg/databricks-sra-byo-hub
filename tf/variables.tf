variable "databricks_account_id" {
  type        = string
  description = "(Required) The Databricks account ID target for account-level operations"
}

variable "databricks_metastore_id" {
  type        = string
  description = "(Required) Metastore ID in the existing hub to assign the spoke workspace to"
}

variable "location" {
  type        = string
  description = "(Required) The Azure region for the spoke deployment. Must match the region of the existing hub."
}

variable "existing_hub_vnet" {
  type = object({
    vnet_id = string
  })
  description = "(Required) Existing hub VNET details used for spoke peering"
}

# ------------------------------------------------------------------
# Workspace Variables
variable "create_workspace_resource_group" {
  type        = string
  description = "(Optional) Should a resource group be created for this workspace? If false, resource_group_name must be provided."
  default     = true
}

variable "existing_resource_group_name" {
  type        = string
  description = "(Optional) Existing resource group name, if using one"
  default     = null
}

variable "resource_suffix" {
  type        = string
  description = "(Required) Suffix to use for naming Azure resources (e.g. dbx-dev, sra, etc.)"
}

variable "create_workspace_vnet" {
  type        = bool
  description = "(Optional) Whether to create SRA-managed workspace VNET. If false, workspace_vnet must be provided."
  default     = true
}

variable "workspace_vnet" {
  type = object({
    cidr     = string
    new_bits = optional(number, null)
  })
  description = "(Optional) Spoke network configuration - required when create_workspace_vnet is true."
  default     = null

  validation {
    condition     = var.create_workspace_vnet ? var.workspace_vnet != null : true
    error_message = "workspace_vnet must be provided when create_workspace_vnet is true"
  }
  validation {
    condition     = !var.create_workspace_vnet ? var.workspace_vnet == null : true
    error_message = "workspace_vnet must not be provided when create_workspace_vnet is false"
  }
}

variable "existing_workspace_vnet" {
  type = object({
    network_configuration = object({
      virtual_network_id                                   = string
      private_subnet_id                                    = string
      public_subnet_id                                     = string
      private_endpoint_subnet_id                           = string
      private_subnet_network_security_group_association_id = string
      public_subnet_network_security_group_association_id  = string
    })
    dns_zone_ids = object({
      backend = string
      dfs     = string
      blob    = string
    })
  })
  description = "(Optional) Existing network configuration - required when create_workspace_vnet is false"
  default     = null

  validation {
    condition     = !var.create_workspace_vnet ? var.existing_workspace_vnet != null : true
    error_message = "existing_workspace_vnet must be provided when create_workspace_vnet is false"
  }

  validation {
    condition     = var.create_workspace_vnet ? var.existing_workspace_vnet == null : true
    error_message = "existing_workspace_vnet should only be provided when create_workspace_vnet is false"
  }
}

variable "existing_ncc_id" {
  type        = string
  description = "(Required) ID of the existing NCC in the hub to bind the spoke workspace to"
}

variable "existing_ncc_name" {
  type        = string
  description = "(Optional) Name of the existing NCC. Only used in private endpoint approval descriptions."
  default     = null
}

variable "existing_network_policy_id" {
  type        = string
  description = "(Required) ID of the existing account network policy to apply to the spoke workspace"
}

variable "existing_cmk_ids" {
  type = object({
    key_vault_id            = string
    managed_disk_key_id     = string
    managed_services_key_id = string
  })
  description = "(Optional) Existing CMK IDs from the hub - required when cmk_enabled is true"
  default     = null

  validation {
    condition     = var.cmk_enabled ? var.existing_cmk_ids != null : true
    error_message = "existing_cmk_ids must be provided when cmk_enabled is true"
  }
}

variable "cmk_enabled" {
  type        = bool
  description = "(Optional) Whether to enable customer-managed keys (CMK) for workspace encryption. When enabled, managed disks and services will be encrypted with customer-managed keys."
  default     = true
}

variable "workspace_security_compliance" {
  type = object({
    automatic_cluster_update_enabled      = optional(bool, null)
    compliance_security_profile_enabled   = optional(bool, null)
    compliance_security_profile_standards = optional(list(string), [])
    enhanced_security_monitoring_enabled  = optional(bool, null)
  })
  description = "(Optional) Enhanced security compliance configuration for the workspace"
  default     = null

  validation {
    condition     = var.workspace_security_compliance != null && length(var.workspace_security_compliance.compliance_security_profile_standards) > 0 ? var.workspace_security_compliance.compliance_security_profile_enabled == true : true
    error_message = "If a compliance standard is provided in var.workspace_security_compliance.compliance_security_profile_standards, var.workspace_security_compliance.compliance_security_profile_enabled must be true."
  }
}

variable "workspace_name_overrides" {
  type        = map(string)
  description = "(Optional) Override names for workspace resources. Keys should match naming module outputs."
  default     = {}
}

variable "tags" {
  type        = map(string)
  description = "(Optional) Map of tags to attach to resources"
  default     = {}
}

variable "subscription_id" {
  type        = string
  description = "(Required) Azure Subscription ID to deploy into"
}

variable "catalog_force_destroy" {
  type        = bool
  default     = false
  description = "Used to allow Terraform to force destroy the catalog. This is only used for testing SRA."
}
