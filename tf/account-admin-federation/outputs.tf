output "account_admin_client_id" {
  value       = databricks_service_principal.account_admin.application_id
  description = "Application (client) ID of the account-admin service principal. Put this in the SPOKE var file as account_admin_client_id."
}

output "account_admin_sp_id" {
  value       = databricks_service_principal.account_admin.id
  description = "Numeric account service principal ID (for reference; the federation policy already uses it)."
}
