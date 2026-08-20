provider "azurerm" {
  features {}
  subscription_id = var.subscription_id

  # use_oidc lets the workspace UAMI authenticate via the Azure DevOps Workload Identity Federation service connection
  # when this layer runs from a pipeline (the AzureCLI@2 task exports ARM_USE_OIDC / ARM_OIDC_TOKEN / ARM_CLIENT_ID /
  # ARM_TENANT_ID). Harmless for a local `az login` run, which uses the CLI credential instead. See tf/bootstrap/README.md.
  use_oidc = var.use_oidc
}

provider "azapi" {
  subscription_id = var.subscription_id
  use_oidc        = var.use_oidc
}

# Account-plane provider - OPT-IN, EXPLICIT alias. Account admin is not ambient: a resource runs as this SP only when it
# names `provider = databricks.account`, which is greppable and an obvious review flag. Only the account-admin-gated
# resources (metastore assignment, NCC binding, workspace network option, NCC private endpoint rule) use it. See the
# Least-Privilege Provider Default spec.
#
# Authenticates as a dedicated Databricks account service principal via OAuth token federation. In a pipeline
# (account_admin_client_id set), the provider exchanges a runtime OIDC token for a short-lived Databricks OAuth token AS
# this SP - no Azure identity, no secret, no ARM_* collision. auth_type selects the path (var.account_admin_auth_type):
#   - azure-devops-oidc (default): exchanges the ADO pipeline's OIDC token, mapped to SYSTEM_ACCESSTOKEN.
#   - github-oidc: fetches a GitHub Actions OIDC token (via ACTIONS_ID_TOKEN_REQUEST_*, present with id-token: write) and
#     requests it with `audience` = the Databricks account ID, matching the account SP's GitHub federation policy (whose
#     audiences default to the account ID). GitHub's own default token audience is https://github.com/<org>, which would
#     NOT match - so `audience` must be set explicitly here. The GitHub reusable workflow sets github-oidc via TF_VAR.
# The SP holds account admin and its federation policy is set up once by a human account admin (see
# tf/account-admin-federation and the Account Admin OAuth Federation spec). Empty client_id on a local run as yourself
# (already an account admin) - null lets the provider fall back to ambient az-cli auth.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id

  client_id = var.account_admin_client_id != "" ? var.account_admin_client_id : null
  auth_type = var.account_admin_client_id != "" ? var.account_admin_auth_type : null

  # OIDC token audience for the github-oidc path only (the TF provider argument is `audience`, not `token_audience`).
  # Null for azure-devops-oidc / local az-cli, where it is unused.
  audience = var.account_admin_client_id != "" && var.account_admin_auth_type == "github-oidc" ? var.databricks_account_id : null
}

# DEFAULT (unaliased) provider = the least-privileged WORKSPACE UAMI. Any resource that does not explicitly name a
# provider inherits this, so new resources are least-privilege by default; reaching for account admin requires the
# explicit databricks.account alias above. Authenticates as the WORKSPACE UAMI via ambient Azure auth (ARM_* from the
# AzureCLI@2 task in CI, or az-cli locally) - NOT the account SP. This stays correct only because we never set the global
# DATABRICKS_* env vars (DATABRICKS_AUTH_TYPE/CLIENT_ID); the account SP's auth lives entirely in the account-plane
# provider block above, and only SYSTEM_ACCESSTOKEN is placed in the environment.
#
# The host is only known after the workspace is created, so this default is used exclusively by resources that run after
# the workspace exists (the catalog module). The workspace module is passed only databricks.account explicitly and never
# consumes this default, so there is no provider/module cycle despite the self-referential host.
provider "databricks" {
  host = module.spoke_workspace.workspace_url
}

# These blocks are not required by terraform, but they are here to silence TFLint warnings
provider "null" {}

provider "time" {}
