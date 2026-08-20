variable "databricks_account_id" {
  type        = string
  description = "(Required) Databricks account ID (account host https://accounts.azuredatabricks.net)."
}

variable "account_admin_display_name" {
  type        = string
  description = "(Required) Display name for the dedicated account-admin service principal, e.g. sp-prod-account-admin. One per landing zone."
}

variable "policy_id" {
  type        = string
  description = "(Required) Federation policy identifier, e.g. ado-prod-account-admin. Unique per policy on the service principal."
}

# --- Azure DevOps federation coordinates (identify the pipeline whose OIDC token is trusted) ---

variable "azure_devops_organization_id" {
  type        = string
  description = "(Required) Azure DevOps organization ID (GUID). Forms the OIDC issuer https://vstoken.dev.azure.com/<org-id>."
}

variable "azure_devops_organization_name" {
  type        = string
  description = "(Required) Azure DevOps organization NAME (the dev.azure.com/<org> slug). Part of the OIDC subject."
}

variable "azure_devops_project_name" {
  type        = string
  description = "(Required) Azure DevOps project name hosting the spoke pipeline. Part of the OIDC subject."
}

variable "spoke_pipeline_name" {
  type        = string
  description = <<-EOT
    (Required) Name of the Azure DevOps pipeline that runs the spoke layer. The federation subject is
    p://<org>/<project>/<pipeline>, so this must match the pipeline's name exactly. One policy covers all stages of the
    pipeline; a separate pipeline (e.g. a different landing zone) needs its own policy (or its own SP).
  EOT
}
