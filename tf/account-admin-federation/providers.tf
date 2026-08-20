# Account-host Databricks provider. Run this config as a HUMAN Databricks ACCOUNT ADMIN via `az login` (azure-cli auth);
# creating an account service principal and a federation policy are account-admin operations. This is the only place
# that needs interactive account-admin auth - the spoke pipeline never does.
provider "databricks" {
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  auth_type  = "azure-cli"
}
