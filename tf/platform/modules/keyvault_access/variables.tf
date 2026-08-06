variable "key_vault_id" {
  type        = string
  description = "(Required) ARM resource ID of the shared Key Vault to connect to"
}

variable "resource_suffix" {
  type        = string
  description = "(Required) Naming suffix for resources"
}

variable "resource_group_name" {
  type        = string
  description = "(Required) Resource group for the zone, VNet links, and private endpoint. The same security resource group that holds the vault - see the comment in main.tf for why these are not placed per spoke."
}

variable "location" {
  type        = string
  description = "(Required) Azure region. Must match the region of the VNet holding the private endpoint subnet."
}

variable "private_endpoint_subnet_id" {
  type        = string
  description = "(Required) Pre-existing subnet to place the vault's private endpoint NIC in. Must exist before this layer applies."
}

variable "spoke_virtual_network_ids" {
  type        = map(string)
  description = "(Optional) Pre-existing spoke VNets to link to the privatelink.vaultcore.azure.net zone, keyed by a short name used in the link name. One entry per spoke that should resolve the vault privately."
  default     = {}
}

variable "tags" {
  type        = map(string)
  description = "(Optional) Map of tags to attach to resources"
  default     = {}
}
