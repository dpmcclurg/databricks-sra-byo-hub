variable "databricks_account_id" {
  type        = string
  description = "(Required) The Databricks account ID target for account-level operations"
}

variable "account_admin_client_id" {
  type        = string
  default     = ""
  description = <<-EOT
    (Optional) Application (client) ID of the dedicated Databricks account service principal that runs the four
    account-admin-gated resources (metastore assignment, NCC binding, NCC private-endpoint rule, workspace network
    option). The account-host `databricks` provider uses it with auth_type=azure-devops-oidc to exchange the pipeline's
    OIDC token for a Databricks OAuth token as this SP - no Azure identity, no secret. The SP, its account-admin
    membership, and its federation policy are set up once by a human account admin (see tf/account-admin-federation).
    Leave empty for a local run as yourself (an account admin), where the provider falls back to ambient `az-cli` auth.
  EOT
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
  description = "(Optional) Existing hub VNET details used for spoke peering. Required when create_hub_peering is true; may be null otherwise, since nothing then references the hub network."
  default     = null

  validation {
    condition     = var.create_hub_peering ? var.existing_hub_vnet != null : true
    error_message = "existing_hub_vnet must be provided when create_hub_peering is true"
  }
}

# Whether this configuration creates the spoke half of the hub peering.
#
# Azure models a peering as two resources, one per VNet, and this configuration can only ever create the spoke one, since
# the hub is customer-managed. But even that half needs permissions on the *hub* network: ARM authorizes the operation
# against the linked VNet, requiring Microsoft.Network/virtualNetworks/peer/action there, and fails with
# LinkedAuthorizationFailed without it. That is often unavailable when the hub is in another subscription. See
# https://learn.microsoft.com/en-us/azure/virtual-network/create-peering-different-subscriptions
#
# Setting this to false hands both halves off instead; run `terraform output hub_peering_command` for the commands. Only
# meaningful when create_workspace_vnet is true, since the peering lives in the VNet module. Nothing else here depends on
# the peering - the workspace and its private endpoints are built over the spoke VNet regardless - but classic compute has
# no path to on-premises until both halves exist with gateway transit set.
variable "create_hub_peering" {
  type        = bool
  description = "(Optional) Whether to create the spoke half of the hub peering. Set to false when the provisioner lacks Microsoft.Network/virtualNetworks/peer/action on the hub network, and have the network team create both halves instead."
  default     = true
}

# ------------------------------------------------------------------
# Workspace Variables
# bool, not string. As a string this silently accepted "true"/"false" and made the validations on
# existing_resource_group_name unreliable, since negating a string is not the same as negating a bool.
variable "create_workspace_resource_group" {
  type        = bool
  description = "(Optional) Whether to create the resource group for this workspace. When false, existing_resource_group_name must be provided - normally the resource group the network team created for this spoke's VNet."
  default     = true
}

variable "existing_resource_group_name" {
  type        = string
  description = "(Optional) Existing resource group name, if using one. Only read when create_workspace_resource_group is false."
  default     = null

  validation {
    condition     = !var.create_workspace_resource_group ? var.existing_resource_group_name != null : true
    error_message = "existing_resource_group_name must be provided when create_workspace_resource_group is false"
  }

  # Catches the easy mistake: naming an existing resource group but leaving create_workspace_resource_group at its default
  # of true. The name is then ignored and the apply fails partway through with "a resource with the ID ... already exists"
  # on a resource group the operator explicitly asked to reuse.
  validation {
    condition     = var.existing_resource_group_name != null ? !var.create_workspace_resource_group : true
    error_message = "existing_resource_group_name is set, so create_workspace_resource_group must be false. Otherwise this configuration tries to create the resource group instead of reusing it."
  }
}

variable "resource_suffix" {
  type        = string
  description = "(Required) Suffix to use for naming Azure resources (e.g. dbx-dev, sra, etc.)"
}

variable "create_workspace_vnet" {
  type        = bool
  description = "(Optional) Whether this configuration creates the workspace VNET. If false, existing_workspace_vnet must be provided."
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

# The shared Key Vault and CMKs owned by the platform layer in tf/platform.
#
# Apply tf/platform first, then run `terraform output -raw spoke_tfvars_snippet` there and paste the result into this
# spoke's var file. Plain variables are used rather than terraform_remote_state so that a spoke principal never needs read
# access to the platform state file, and so that a spoke plan does not depend on the platform backend.
#
# The vault must be in the same region and Microsoft Entra ID tenant as this workspace - a different subscription is
# allowed, a different region is not - so var.location must match the platform layer's location. Nothing in Terraform
# catches a mismatch; Azure rejects the workspace create with an unhelpful error.
#
# Note the asymmetry in what is supplied. Managed services and managed disk take versioned key URIs, because that is what
# the typed workspace attributes accept. DBFS root takes the vault URI plus key name and version separately, because it
# is applied as an ARM body - see modules/workspace/dbfs_root_cmk.tf.
variable "platform_cmk" {
  type = object({
    key_vault_id  = string
    key_vault_uri = string

    managed_services_key_id = string
    managed_disk_key_id     = string

    dbfs_root_key_name    = string
    dbfs_root_key_version = string
  })
  description = "(Optional) The shared Key Vault and CMK identifiers produced by the platform layer in tf/platform. Required when cmk_enabled is true. Generate with `terraform output -raw spoke_tfvars_snippet`."
  default     = null

  validation {
    condition     = var.cmk_enabled ? var.platform_cmk != null : true
    error_message = "platform_cmk must be provided when cmk_enabled is true. Apply tf/platform first, then copy its spoke_tfvars_snippet output."
  }

  # Databricks requires a specific key version rather than "latest". A versionless key ID silently violates that
  # contract, so reject IDs that do not carry a version segment.
  validation {
    condition = var.platform_cmk == null ? true : alltrue([
      for id in [
        var.platform_cmk.managed_services_key_id,
        var.platform_cmk.managed_disk_key_id,
      ] :
      length(regexall("/keys/[^/]+/[^/]+$", id)) > 0
    ])
    error_message = "CMK key IDs must include a key version (https://<vault>.vault.azure.net/keys/<name>/<version>), not a versionless ID"
  }

  # Catches a resource ID pasted into a key URI slot, or vice versa - the two are easy to transpose and the resulting
  # Azure error does not point at the cause.
  validation {
    condition     = var.platform_cmk == null ? true : can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.KeyVault/vaults/[^/]+$", var.platform_cmk.key_vault_id))
    error_message = "platform_cmk.key_vault_id must be a Microsoft.KeyVault/vaults ARM resource ID"
  }

  validation {
    condition     = var.platform_cmk == null ? true : can(regex("^https://", var.platform_cmk.key_vault_uri))
    error_message = "platform_cmk.key_vault_uri must be the vault's URI (https://<vault>.vault.azure.net/)"
  }
}

variable "security_resource_group_name" {
  type        = string
  description = "(Optional) Name of the platform layer's security resource group, in this subscription. Required only when place_access_connectors_in_security_rg is true."
  default     = null

  validation {
    condition     = var.place_access_connectors_in_security_rg ? var.security_resource_group_name != null : true
    error_message = "security_resource_group_name is required when place_access_connectors_in_security_rg is true"
  }
}

# Placement only. Each spoke still gets its own pair of access connectors, with roles scoped to its own storage accounts -
# sharing the identities themselves would let any workspace holding the Unity Catalog credential reach every other spoke's
# catalog storage.
variable "place_access_connectors_in_security_rg" {
  type        = bool
  description = "(Optional) Create this spoke's two Databricks access connectors in the platform security resource group instead of the workspace resource group. Placement only - the connectors are still per-spoke."
  default     = false
}

# Single switch covering all three Azure Databricks CMK scopes - there is no per-scope toggle. When true, the workspace
# is configured with customer-managed keys for managed services, DBFS root, and managed disks, and infrastructure
# encryption is enabled, using the keys supplied in var.platform_cmk. When false, the workspace uses platform-managed keys
# and no vault is involved.
#
# Note that Azure Databricks documents managed disk CMK as not disableable once enabled for a workspace, so setting this
# back to false after an apply will not undo that scope. See
# https://learn.microsoft.com/en-us/azure/databricks/security/keys/cmk-managed-disks-azure/
variable "cmk_enabled" {
  type        = bool
  description = "(Optional) Whether to configure customer-managed keys for the workspace, using the shared vault in var.platform_cmk. Covers managed services, DBFS root, and managed disks together, plus infrastructure encryption."
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

variable "use_oidc" {
  type        = bool
  default     = false
  description = "(Optional) Authenticate the azurerm/azapi providers via OIDC (Azure DevOps Workload Identity Federation). Leave false for local `az login` runs; the pipeline sets it true. See tf/bootstrap/README.md."
}

variable "catalog_force_destroy" {
  type        = bool
  default     = false
  description = "(Optional) Allow Terraform to force destroy the catalog. Intended for test deployments only."
}

variable "catalog_owner_group" {
  type        = string
  default     = null
  description = <<-EOT
    (Optional, strongly recommended) Account-level group set as OWNER of the spoke's storage credential, external
    location, and catalog. Set this in every real deployment so a durable group - not the ephemeral workspace UAMI -
    owns the UC securables; this keeps ownership intact when the deployment identity is recreated. The group must already
    exist at the account level and should contain the deployment identity so the pipeline retains MANAGE across re-runs.
    Leave null only for throwaway/self-contained test deployments.
  EOT
}
