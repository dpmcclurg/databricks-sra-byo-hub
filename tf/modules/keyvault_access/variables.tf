variable "key_vault_id" {
  type        = string
  description = "(Required) ARM resource ID of the shared Key Vault to connect to. Owned by the platform layer, not by this module."
}

variable "resource_suffix" {
  type        = string
  description = "(Required) Naming suffix for resources"
}

variable "resource_group_name" {
  type        = string
  description = "(Required) Resource group for the zone, VNet link, and private endpoint. This is the workspace resource group - see the comment in main.tf for why these are not placed with the vault."
}

variable "location" {
  type        = string
  description = "(Required) Azure region. Must match the region of the VNet holding the private endpoint subnet."
}

variable "private_endpoint_subnet_id" {
  type        = string
  description = "(Required) Subnet in this spoke to place the vault's private endpoint NIC in"
}

variable "virtual_network_id" {
  type        = string
  description = "(Required) This spoke's VNet, linked to the private DNS zone so in-VNet clients resolve the vault privately"
}

variable "tags" {
  type        = map(string)
  description = "(Optional) Map of tags to attach to resources"
  default     = {}
}
