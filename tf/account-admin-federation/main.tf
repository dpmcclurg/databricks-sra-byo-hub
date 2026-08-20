# The dedicated Databricks account service principal that the spoke's account-host provider authenticates as. It runs the
# four account-admin-gated resources (metastore assignment, NCC binding, NCC private-endpoint rule, workspace network
# option). It is NOT an Azure identity - it lives entirely in the Databricks account.
#
# NOTE: making this SP a Databricks ACCOUNT ADMIN is a deliberate MANUAL step (account console -> add to the account
# `admins` group), not managed here - same rationale as before: keep Terraform out of granting account admin. See README.
resource "databricks_service_principal" "account_admin" {
  display_name = var.account_admin_display_name
}

# OAuth token federation trust: allows the Azure DevOps pipeline (identified by the OIDC subject below) to obtain a
# Databricks OAuth token AS this service principal - no secret. Verified against the ADO provider federation doc:
#   issuer   = https://vstoken.dev.azure.com/<org-id>   (the pipeline's built-in OIDC, NOT the Entra ARM issuer)
#   subject  = p://<org-name>/<project-name>/<pipeline-name>
#   audience = api://AzureADTokenExchange
resource "databricks_service_principal_federation_policy" "ado" {
  service_principal_id = tonumber(databricks_service_principal.account_admin.id)
  policy_id            = var.policy_id

  oidc_policy = {
    issuer        = "https://vstoken.dev.azure.com/${var.azure_devops_organization_id}"
    subject       = "p://${var.azure_devops_organization_name}/${var.azure_devops_project_name}/${var.spoke_pipeline_name}"
    subject_claim = "sub"
    audiences     = ["api://AzureADTokenExchange"]
  }
}
