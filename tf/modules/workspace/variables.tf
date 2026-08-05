variable "network_configuration" {
  type = object({
    virtual_network_id                                   = string
    private_subnet_id                                    = string
    public_subnet_id                                     = string
    private_endpoint_subnet_id                           = string
    private_subnet_network_security_group_association_id = string
    public_subnet_network_security_group_association_id  = string
  })
  description = "The network configuration for the workspace"
}

variable "resource_group_name" {
  type        = string
  description = "(Required) The name of the resource group to deploy the workspace to"
}

variable "is_kms_enabled" {
  type        = bool
  description = "(Optional - default to true) Enable KMS (Azure Key Vault) encryption for resources"
  default     = true
}

variable "is_frontend_private_link_enabled" {
  type        = bool
  description = "(Optional - default to false) Enable frontend Private Link for Databricks workspace. When true, disables public network access."
  default     = false
}

# Secures the workspace default storage account by setting default_storage_firewall_enabled on the workspace, which
# blocks public network access to it. Provisions the private endpoints, NCC endpoints, and access connector that the
# firewall requires.
#
# This is unrelated to whether DBFS is used: the default storage account is mandatory for every workspace and holds
# workspace system data regardless. Disabling DBFS root and mounts is a separate, workspace-level setting that this
# template does not manage.
variable "secure_workspace_default_storage" {
  description = "(Optional) Block public access to the workspace default storage account and provision private connectivity to it"
  type        = bool
  default     = true
}

variable "location" {
  type        = string
  description = "(Required) The location for the spoke deployment"
}

variable "key_vault_id" {
  type        = string
  description = "(Required) ID of the Azure Key Vault containing the keys for CMK"
}

variable "metastore_id" {
  type        = string
  description = "(Required) The ID of the metastore to associate with the Databricks workspace"
}

variable "dbfs_root_key_id" {
  type        = string
  description = "(Required) The key for workspace storage account (DBFS root) encryption"
}

variable "managed_disk_key_id" {
  type        = string
  description = "(Required) The key for managed disk encryption"
}

variable "managed_services_key_id" {
  type        = string
  description = "(Required) The key for the managed services encryption"
}

variable "resource_suffix" {
  type        = string
  description = "(Required) Naming resource_suffix for resources"
}

variable "tags" {
  type        = map(string)
  description = "(Optional) Map of tags to attach to resources"
  default     = {}
}

variable "ncc_id" {
  type        = string
  description = "ID of the NCC to use for this workspace"
}

variable "ncc_name" {
  type        = string
  description = "Name of the NCC to use for this workspace"
}

variable "network_policy_id" {
  type        = string
  description = "ID of the network policy to use for this workspace"
}

variable "provisioner_principal_id" {
  type        = string
  description = "Principal ID of the user running this terraform"
}

variable "databricks_account_id" {
  type        = string
  description = "Databricks account ID"
}

variable "dns_zone_ids" {
  type = object({
    backend = string
    dfs     = string
    blob    = string
  })
  description = "Private DNS zone IDs for backend, dfs, and blob"
}

variable "name_overrides" {
  type        = map(string)
  description = "(Optional) Override names for resources. Keys should match naming module outputs (e.g., 'databricks_workspace', 'private_endpoint', 'resource_group')."
  nullable    = false
  default     = {}
}

variable "create_backend_private_endpoint" {
  type        = bool
  description = "(Optional) Whether to create the backend private endpoint. Set to false if managing PEs externally."
  default     = true
}

variable "create_webauth_private_endpoint" {
  type        = bool
  description = "(Optional) Whether to create the webauth (browser_authentication) private endpoint for SSO. Typically only used for hub WEBAUTH workspace."
  default     = false
}

variable "enhanced_security_compliance" {
  description = "(Optional) Enhanced security compliance configuration."
  type = object({
    automatic_cluster_update_enabled      = optional(bool, null)
    compliance_security_profile_enabled   = optional(bool, null)
    compliance_security_profile_standards = optional(list(string), null)
    enhanced_security_monitoring_enabled  = optional(bool, null)
  })
  nullable = false
  default  = {}
}
