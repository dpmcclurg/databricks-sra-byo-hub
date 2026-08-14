# Bootstrap layer: the CI/CD identities and shared state storage for one subscription.
#
# This layer is provisioned by the single, manually-created foundational UAMI described in the README (id-cicd-foundational,
# Managed Identity Contributor + RBAC Administrator on the subscription, federated to a bootstrap service connection). It
# creates, per environment served by this subscription:
#
#   - the security resource group and the spoke resource group,
#   - a platform UAMI in the security RG and a workspace UAMI in the spoke RG (identities co-located with what they
#     provision, per the design),
#   - one federated identity credential per UAMI, trusting that env's Azure DevOps service connection,
#   - the least-privilege role assignments each UAMI needs to run its layer.
#
# It also creates the storage account that holds every layer's Terraform state for this subscription.
#
# Run once per subscription: one apply for the NON-PROD subscription (environments = dev + test) and one for PROD
# (environments = prd). The environments map drives everything with for_each, so the two applies differ only by var file.

locals {
  tags = { for name, value in var.tags : lower(name) => value }

  bootstrap_rg_name = coalesce(var.bootstrap_resource_group_name, "rg-cicd-bootstrap")

  # Azure DevOps Workload Identity Federation coordinates. The issuer is per-organization; the subject encodes the
  # specific service connection. A UAMI federated credential matching (issuer, subject, audience) lets the pipeline's
  # OIDC token be exchanged for a token AS that UAMI. See the README.
  ado_issuer   = "https://vstoken.dev.azure.com/${var.azure_devops_organization_id}"
  ado_audience = "api://AzureADTokenExchange"

  # Flatten environments into per-hub grants: one Network Contributor assignment per (env, hub VNet). Keyed so a hub can
  # be added or removed without disturbing the others.
  workspace_hub_peering_grants = merge([
    for env_key, env in var.environments : {
      for hub_id in env.hub_virtual_network_ids :
      "${env_key}:${hub_id}" => { env_key = env_key, hub_id = hub_id }
    }
  ]...)
}

# ---------------------------------------------------------------------------------------------------------------------
# Shared bootstrap resources: the RG that holds the tfstate account, and the account itself.
# ---------------------------------------------------------------------------------------------------------------------

# The bootstrap resource group is a MANUAL prerequisite, not managed here: the README has you create it by hand (along
# with the foundational UAMI it holds) before this layer can run, because the identity that runs this layer must already
# exist. So it is read as a data source rather than created - otherwise the apply collides with the manually-created RG
# ("a resource with the ID ... already exists").
data "azurerm_resource_group" "bootstrap" {
  name = local.bootstrap_rg_name
}

# Subscription scope, used for the workspace UAMI's storage private-endpoint-approval custom role (see rbac.tf). The
# target - the workspace default storage account - lives in the Databricks-managed resource group, whose name is not
# known until the workspace exists, so the role is defined and assigned at subscription scope rather than that RG.
data "azurerm_subscription" "current" {}

# Holds the Terraform state for every layer in this subscription (bootstrap, platform, and each spoke). AAD auth only -
# no storage keys - so access is governed by RBAC and each pipeline's UAMI is granted Storage Blob Data Contributor
# below rather than handed a shared key.
resource "azurerm_storage_account" "tfstate" {
  name                     = var.tfstate_storage_account_name
  resource_group_name      = data.azurerm_resource_group.bootstrap.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
  account_kind             = "StorageV2"

  # State is sensitive and access is by AAD identity, never by shared key.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------------------------------------------------
# Per-environment resource groups. Created here so the UAMIs can live inside them (the identity must pre-exist before the
# pipeline that provisions the rest of the RG runs). The platform and spoke layers then run with
# create_*_resource_group = false and point at these.
# ---------------------------------------------------------------------------------------------------------------------

resource "azurerm_resource_group" "security" {
  for_each = var.environments

  name     = "rg-${each.value.resource_suffix}-security"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "spoke" {
  for_each = var.environments

  name     = "rg-${each.value.resource_suffix}"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------------------------------------------------
# Platform UAMI - one per environment, in that env's security RG. Runs the platform layer (vault + CMKs).
# ---------------------------------------------------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "platform" {
  for_each = var.environments

  name                = "id-${each.value.resource_suffix}-platform"
  resource_group_name = azurerm_resource_group.security[each.key].name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "platform" {
  for_each = var.environments

  name      = "adodeploy-platform"
  parent_id = azurerm_user_assigned_identity.platform[each.key].id

  audience = [local.ado_audience]
  issuer   = local.ado_issuer
  subject  = "sc://${var.azure_devops_organization_name}/${var.azure_devops_project_name}/${each.value.platform_service_connection}"
}

# ---------------------------------------------------------------------------------------------------------------------
# Workspace UAMI - one per environment, in that env's spoke RG. Runs the spoke layer (workspace + VNet + catalog).
# ---------------------------------------------------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "workspace" {
  for_each = var.environments

  name                = "id-${each.value.resource_suffix}-workspace"
  resource_group_name = azurerm_resource_group.spoke[each.key].name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "workspace" {
  for_each = var.environments

  name      = "adodeploy-workspace"
  parent_id = azurerm_user_assigned_identity.workspace[each.key].id

  audience = [local.ado_audience]
  issuer   = local.ado_issuer
  subject  = "sc://${var.azure_devops_organization_name}/${var.azure_devops_project_name}/${each.value.workspace_service_connection}"
}
