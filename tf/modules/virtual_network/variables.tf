variable "resource_group_name" {
  type        = string
  description = "(Required) Name of the resource group to use"
}

variable "location" {
  type        = string
  description = "(Required) The location for the spoke deployment"
}

variable "vnet_cidr" {
  # Note: following chart assumes a Vnet between /16 and /24, inclusive

  # | Subnet Size (CIDR) | Maximum ADB Cluster Nodes |
  # | /17	| 32763 |
  # | /18	| 16379 |
  # | /19	| 8187 |
  # | /20	| 4091 |
  # | /21	| 2043 |
  # | /22	| 1019 |
  # | /23	| 507 |
  # | /24	| 251 |
  # | /25	| 123 |
  # | /26	| 59 |

  type        = string
  description = "(Required) The CIDR block for the spoke Virtual Network"
  validation {
    condition     = tonumber(split("/", var.vnet_cidr)[1]) > 15 && tonumber(split("/", var.vnet_cidr)[1]) < 25
    error_message = "CIDR block must be between /16 and /24, inclusive"
  }
}

variable "workspace_subnets" {
  type = object({
    create   = optional(bool, true)
    new_bits = optional(number, 2)
  })
  description = "(Optional) Workspace subnet configuration"
  default     = {}
}

variable "private_link_subnet" {
  type = object({
    create   = optional(bool, true)
    new_bits = optional(number, 3)
  })
  description = "(Optional) Private Link subnet configuration"
  default     = {}
}

variable "extra_subnets" {
  type = map(object({
    name     = string
    new_bits = number
  }))
  description = "(Optional) Set of extra subnets to create in VNET"
  default     = {}
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

variable "virtual_network_peerings" {
  type = map(object({
    name                      = optional(string, "")
    remote_virtual_network_id = string

    # Declare flags as optional with default values. These must be declared here - Terraform silently drops object
    # attributes that are not part of the declared type, so callers setting them would otherwise have no effect.
    allow_gateway_transit   = optional(bool, false)
    use_remote_gateways     = optional(bool, false)
    allow_forwarded_traffic = optional(bool, true)
  }))
  description = "(Optional) Map of virtual network peers"
  default     = {}
}
