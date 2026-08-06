variable "resource_suffix" {
  type        = string
  description = "(Required) Naming suffix for resources"
}

variable "resource_group_name" {
  type        = string
  description = "(Required) Name of the resource group to create the vault in"
}

variable "location" {
  type        = string
  description = "(Required) Azure region. Every workspace served by this vault must be in the same region - Azure Databricks does not allow a vault to serve a workspace in another region."
}

variable "tenant_id" {
  type        = string
  description = "(Required) Microsoft Entra ID tenant of the vault. Must match the tenant of every workspace it serves."
}

variable "key_vault_name" {
  type        = string
  description = "(Optional) Explicit vault name. Strongly recommended for this shared vault: it makes the name reproducible from configuration rather than from state, so an accidental destroy can be recovered by re-applying. Falls back to a random-suffixed generated name."
  default     = null
}

variable "key_name_prefix" {
  type        = string
  description = "(Optional) Prefix for the three CMK names. Defaults to the generated naming-module prefix. Set explicitly alongside key_vault_name for reproducibility."
  default     = null
}

variable "databricks_service_principal_object_id" {
  type        = string
  description = "(Optional) Object ID of the AzureDatabricks enterprise application. Looked up through the azuread provider when null; set explicitly only to avoid a live Microsoft Graph call, e.g. in tests."
  default     = null
}

variable "soft_delete_retention_days" {
  type        = number
  description = "(Optional) Soft-delete retention in days. Defaults to the maximum, since this vault is shared and long-lived."
  default     = 7

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be between 7 and 90"
  }
}

variable "tags" {
  type        = map(string)
  description = "(Optional) Map of tags to attach to resources. Tag names must already be lowercased by the caller - ARM lowercases them on Microsoft.KeyVault/vaults/keys, so mixed-case names never converge."
  default     = {}
}
