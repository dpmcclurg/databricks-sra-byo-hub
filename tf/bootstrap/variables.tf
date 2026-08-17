variable "subscription_id" {
  type        = string
  description = <<-EOT
    (Required) Subscription this bootstrap instance provisions identities for. Run ONE instance of this configuration per
    subscription: one for the NON-PROD subscription (holds the DEV and TEST environments) and one for the PROD
    subscription (holds the PRD environment). The environments served are listed in var.environments.
  EOT
}

variable "use_oidc" {
  type        = bool
  default     = false
  description = "(Optional) Authenticate the azurerm provider via OIDC (Azure DevOps Workload Identity Federation). Leave false for local `az login` runs; the pipeline sets it true. The AzureCLI@2 task also exports ARM_USE_OIDC, so this is belt-and-suspenders."
}

variable "location" {
  type        = string
  description = "(Required) Azure region for the bootstrap resource group, the tfstate storage account, and (by default) the per-environment resource groups. Identities are global, but their resource groups are regional."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "(Optional) Tags applied to all bootstrap-created resources. Tag names are lowercased to match the convention in the platform and spoke layers."
}

# ---------------------------------------------------------------------------------------------------------------------
# Azure DevOps coordinates
# ---------------------------------------------------------------------------------------------------------------------
# These feed the federated identity credentials. Each UAMI trusts exactly one Azure DevOps service connection, matched
# by issuer + subject. The subject encodes org/project/connection, so these must match the service connections you
# create in Azure DevOps byte-for-byte. See the README for how to read them off the "Workload Identity federation
# (manual)" service connection screen.

variable "azure_devops_organization_id" {
  type        = string
  description = <<-EOT
    (Required) Azure DevOps organization ID (a GUID), used to build the federated-credential issuer URL
    `https://vstoken.dev.azure.com/<organization-id>`. This is the organization *ID*, not its name - read it off the
    service connection's issuer field. PLACEHOLDER until you create the org's first service connection.
  EOT
}

variable "azure_devops_organization_name" {
  type        = string
  description = "(Required) Azure DevOps organization NAME (the slug in dev.azure.com/<org>), used to build the federated-credential subject `sc://<org>/<project>/<connection>`."
}

variable "azure_devops_project_name" {
  type        = string
  description = "(Required) Azure DevOps project name that hosts the pipelines, used in the federated-credential subject."
}

# NOTE: bootstrap has no account-admin identity input. The account plane authenticates as a dedicated Databricks account
# service principal via OAuth token federation, set up once per landing zone by a human account admin (see
# tf/account-admin-federation and the Account Admin OAuth Federation spec). The spoke reads that SP's client ID from
# account_admin_client_id in its own var file; nothing about it is bootstrapped in Azure.

# ---------------------------------------------------------------------------------------------------------------------
# GitHub Actions coordinates (optional, demo/learning path)
# ---------------------------------------------------------------------------------------------------------------------
# The repo runs a manually-triggered GitHub Actions workflow as an alternative CI/CD demonstration alongside Azure
# DevOps. When set, each UAMI additionally trusts a GitHub Actions OIDC token for its "<env>-<layer>" GitHub Environment
# so the workflow authenticates as the same identity - no secrets, no extra identities. Leave null to skip GitHub
# federation entirely (the credentials are simply not created).

variable "github_repository" {
  type        = string
  default     = null
  description = <<-EOT
    (Optional) GitHub repository in "<owner>/<name>" form (e.g. "dpmcclurg/databricks-sra-byo-hub") whose GitHub Actions
    workflows deploy these layers. When set, each platform/workspace UAMI gains a GitHub Actions federated credential
    (issuer https://token.actions.githubusercontent.com, subject repo:<owner>/<name>:environment:<env>-<layer>) in
    ADDITION to its Azure DevOps credential. The subject requires a matching GitHub Environment named "<env>-platform" /
    "<env>-workspace" (e.g. dev-platform, dev-workspace). Leave null to skip GitHub federation.
  EOT

  validation {
    condition     = var.github_repository == null ? true : can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must be in \"owner/name\" form, e.g. dpmcclurg/databricks-sra-byo-hub."
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Per-environment identity model
# ---------------------------------------------------------------------------------------------------------------------
# One entry per environment this subscription serves. NON-PROD subscription: { dev = {...}, test = {...} }. PROD
# subscription: { prd = {...} }. Each environment gets a platform UAMI and a workspace UAMI, each co-located in the
# resource group it provisions, each federated to its own service connection.

variable "environments" {
  description = <<-EOT
    (Required) Map of environment key -> environment config. Key is the short env name (dev/test/prd) used in resource
    names and the service-connection subject.

    Per environment:
      resource_suffix                 - suffix for the env's resource names, matching what the platform/spoke layers use
                                         (e.g. "dbx-dev"). The security RG is rg-<suffix>-security, the spoke RG is
                                         rg-<suffix>.
      platform_service_connection     - Azure DevOps service connection name the platform UAMI federates to.
      workspace_service_connection    - Azure DevOps service connection name the workspace UAMI federates to.
      hub_virtual_network_ids         - resource IDs of the hub VNet(s) this env's workspace UAMI must peer the spoke to.
                                         A list because the hub differs by region (and prod vs non-prod); grant one
                                         Network Contributor assignment per hub VNet. Empty list = no hub peering grant
                                         (e.g. create_hub_peering = false; the network team owns both halves).
  EOT
  type = map(object({
    resource_suffix              = string
    platform_service_connection  = string
    workspace_service_connection = string
    hub_virtual_network_ids      = optional(list(string), [])
  }))

  validation {
    condition     = alltrue([for k in keys(var.environments) : can(regex("^[a-z0-9]+$", k))])
    error_message = "environment keys must be lowercase alphanumeric (e.g. dev, test, prd)."
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# tfstate storage
# ---------------------------------------------------------------------------------------------------------------------

variable "tfstate_storage_account_name" {
  type        = string
  description = "(Required) Globally-unique name for the storage account that holds every layer's remote state in this subscription (e.g. sttfstatenonprod). 3-24 lowercase alphanumeric chars."

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.tfstate_storage_account_name))
    error_message = "tfstate_storage_account_name must be 3-24 lowercase alphanumeric characters."
  }
}

variable "bootstrap_resource_group_name" {
  type        = string
  default     = null
  description = "(Optional) Name of the resource group that holds the tfstate storage account (and, in the CI model, the foundational identity's assets). Defaults to rg-cicd-bootstrap."
}

variable "create_bootstrap_resource_group" {
  type        = bool
  default     = true
  description = <<-EOT
    (Optional) Whether this layer creates the bootstrap resource group. Mirrors the create_*_resource_group pattern in
    the spoke/platform layers.
      true  (default, HUMAN-run model): a person with Owner runs the apply and this layer creates the RG. No runner
            identity needs to pre-exist inside it.
      false (CI model): the RG must ALREADY exist, because it holds the manually-created foundational UAMI the pipeline
            authenticates as - which cannot be created by the apply that runs as it - so the RG is read as a data source.
  EOT
}

