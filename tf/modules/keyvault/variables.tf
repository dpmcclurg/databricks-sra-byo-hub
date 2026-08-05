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
  description = "(Required) Azure region. Must match the workspace region - a vault cannot serve a workspace in another region."
}

variable "tenant_id" {
  type        = string
  description = "(Required) Microsoft Entra ID tenant of the vault. Must match the workspace tenant."
}

variable "provisioner_principal_id" {
  type        = string
  description = "(Required) Object ID of the principal running Terraform, granted key management permissions so it can create the keys"
}

variable "private_endpoint_subnet_id" {
  type        = string
  description = "(Required) Subnet in the spoke to place the vault's private endpoint in"
}

variable "virtual_network_id" {
  type        = string
  description = "(Required) Spoke VNet to link the private DNS zone to"
}

variable "soft_delete_retention_days" {
  type        = number
  description = "(Optional) Soft-delete retention in days"
  default     = 7
}

variable "tags" {
  type        = map(string)
  description = "(Optional) Map of tags to attach to resources"
  default     = {}
}
