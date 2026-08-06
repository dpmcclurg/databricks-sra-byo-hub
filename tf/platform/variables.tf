variable "subscription_id" {
  type        = string
  description = "(Required) Azure Subscription ID to deploy into. One instance of this configuration per subscription per region."
}

variable "location" {
  type        = string
  description = <<-EOT
    (Required) The Azure region for the shared vault. Azure Databricks requires the vault to be in the SAME region as
    every workspace it serves - a different subscription is allowed, a different region is not. Every spoke consuming
    this layer must set the same location.
  EOT
}

variable "resource_suffix" {
  type        = string
  description = "(Required) Suffix used for naming resources (e.g. dbx-prod)"
}

variable "create_security_resource_group" {
  type        = bool
  description = "(Optional) Whether to create the security resource group. Set false to deploy into an existing one, e.g. where resource group creation is centrally governed."
  default     = true
}

variable "security_resource_group_name" {
  type        = string
  description = "(Optional) Name for the security resource group this configuration creates. Defaults to rg-<resource_suffix>-security. Ignored when create_security_resource_group is false."
  default     = null
}

variable "existing_security_resource_group_name" {
  type        = string
  description = "(Optional) Name of an existing resource group to deploy the vault into. Required when create_security_resource_group is false."
  default     = null

  validation {
    condition     = var.create_security_resource_group || var.existing_security_resource_group_name != null
    error_message = "existing_security_resource_group_name must be provided when create_security_resource_group is false"
  }
}

variable "key_vault_name" {
  type        = string
  description = <<-EOT
    (Optional but recommended) Explicit vault name, e.g. "kv-dbx-prod-eastus2". Strongly preferred over the generated
    random-suffixed name for this shared vault: it makes the name reproducible from configuration rather than from state,
    so losing the state does not silently produce a second vault, and an accidental destroy can be recovered by
    re-applying. Must be globally unique, 3-24 chars, alphanumeric and hyphens.
  EOT
  default     = null
}

variable "key_name_prefix" {
  type        = string
  description = "(Optional) Prefix for the three CMK names. Set alongside key_vault_name for a fully reproducible deployment."
  default     = null
}

variable "soft_delete_retention_days" {
  type        = number
  description = "(Optional) Soft-delete retention for the vault, in days. Defaults to the maximum of 90, since this vault is shared and long-lived."
  default     = 90
}

variable "databricks_service_principal_object_id" {
  type        = string
  description = "(Optional) Object ID of the AzureDatabricks enterprise application (appId 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d). Resolved through the azuread provider when null. Set explicitly only to avoid a live Microsoft Graph call, e.g. in tests or where directory read is unavailable."
  default     = null
}

# ------------------------------------------------------------------
# Private access to the shared vault
#
# These consume networking this layer does not create. Spoke VNets are built ahead of this configuration by the network
# team, because peering a spoke to the hub needs permissions on the hub network that the Databricks provisioner does not
# hold - so the subnet and VNets referenced below already exist when this applies.
variable "create_key_vault_private_endpoint" {
  type        = bool
  description = <<-EOT
    (Optional) Create a private endpoint to the shared vault, a privatelink.vaultcore.azure.net zone, and a VNet link per
    spoke. Not required for CMK: neither unwrap call traverses it, and Terraform does not need it either since keys are
    created through ARM's control plane. Needed only for in-VNet data-plane access to the vault, such as a Key
    Vault-backed secret scope from classic compute. Requires key_vault_private_endpoint_subnet_id.
  EOT
  default     = true
}

variable "key_vault_private_endpoint_subnet_id" {
  type        = string
  description = "(Optional) Pre-existing subnet for the vault's private endpoint NIC. Required when create_key_vault_private_endpoint is true. The NIC is created by Azure in this configuration's resource group, following the endpoint."
  default     = null

  validation {
    condition     = var.create_key_vault_private_endpoint ? var.key_vault_private_endpoint_subnet_id != null : true
    error_message = "key_vault_private_endpoint_subnet_id is required when create_key_vault_private_endpoint is true"
  }

  validation {
    condition     = var.key_vault_private_endpoint_subnet_id == null ? true : can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.key_vault_private_endpoint_subnet_id))
    error_message = "key_vault_private_endpoint_subnet_id must be a Microsoft.Network/virtualNetworks/subnets ARM resource ID"
  }
}

variable "spoke_virtual_network_ids" {
  type        = map(string)
  description = <<-EOT
    (Optional) Pre-existing spoke VNets to link to the privatelink.vaultcore.azure.net zone, keyed by a short name used in
    the link name, e.g. { spoke1 = "/subscriptions/.../virtualNetworks/vnet-spoke" }. One entry per spoke that should
    resolve the vault privately. Adding a spoke adds a link here, not a second zone - the single platform-owned endpoint
    means one A-record shared by all of them.
  EOT
  default     = {}

  validation {
    condition = alltrue([
      for id in values(var.spoke_virtual_network_ids) :
      can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", id))
    ])
    error_message = "Each value in spoke_virtual_network_ids must be a Microsoft.Network/virtualNetworks ARM resource ID"
  }
}

variable "tags" {
  type        = map(string)
  description = "(Optional) Map of tags to attach to resources. Tag names are lowercased before use - see the comment in main.tf."
  default     = {}
}
