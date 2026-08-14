# Bootstrap layer - one instance per subscription. Copy to a real var file (e.g. bootstrap-nonprod.tfvars,
# bootstrap-prod.tfvars) and fill in. See tf/bootstrap/README.md for the run order and the manual foundational-identity
# prerequisite.

# The subscription this instance provisions identities for.
#   NON-PROD subscription -> environments = { dev, test }
#   PROD subscription     -> environments = { prd }
subscription_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"

location = "eastus2"

tags = {
  Owner       = "you@example.com"
  ManagedBy   = "terraform-bootstrap"
  Environment = "nonprod"
}

# --- Azure DevOps coordinates (PLACEHOLDERS until you create the service connections) ---
# organization_id is the GUID in the service connection's Issuer URL: https://vstoken.dev.azure.com/<org-id>
# organization_name is the slug in dev.azure.com/<org>.
azure_devops_organization_id   = "00000000-0000-0000-0000-000000000000"
azure_devops_organization_name = "my-ado-org"
azure_devops_project_name      = "databricks-platform"

# --- tfstate storage (this layer creates it) ---
tfstate_storage_account_name = "sttfstatenonprod" # 3-24 lowercase alphanumeric, globally unique
# bootstrap_resource_group_name = "rg-cicd-bootstrap"   # optional; this is the default

# --- Environments served by THIS subscription ---
# NON-PROD example (dev + test). For the PROD subscription, use a single prd entry instead.
environments = {
  dev = {
    resource_suffix              = "dbx-dev"
    platform_service_connection  = "sc-dev-platform"
    workspace_service_connection = "sc-dev-workspace"
    # Hub VNet(s) the DEV spoke peers to. Differs by region and prod/non-prod. Empty when create_hub_peering = false.
    hub_virtual_network_ids = [
      # "/subscriptions/<nonprod-sub>/resourceGroups/rg-hub-dev/providers/Microsoft.Network/virtualNetworks/vnet-hub-dev-eastus2",
    ]
  }
  test = {
    resource_suffix              = "dbx-test"
    platform_service_connection  = "sc-test-platform"
    workspace_service_connection = "sc-test-workspace"
    hub_virtual_network_ids = [
      # "/subscriptions/<nonprod-sub>/resourceGroups/rg-hub-test/providers/Microsoft.Network/virtualNetworks/vnet-hub-test-eastus2",
    ]
  }
}

# --- PROD subscription instance would instead use ---
# environments = {
#   prd = {
#     resource_suffix              = "dbx-prod"
#     platform_service_connection  = "sc-prd-platform"
#     workspace_service_connection = "sc-prd-workspace"
#     hub_virtual_network_ids = [
#       "/subscriptions/<prod-sub>/resourceGroups/rg-hub-prd/providers/Microsoft.Network/virtualNetworks/vnet-hub-prd-eastus2",
#     ]
#   }
# }

# --- Optional: grant the workspace UAMIs Unity Catalog privileges on the metastore ---
# Leave unset on the first bootstrap run. Set it once the metastore and at least one attached workspace exist, then
# re-apply bootstrap as a metastore admin. See README "Optional: grant the workspace UAMIs Unity Catalog privileges".
# databricks_metastore_grant = {
#   account_id   = "00000000-0000-0000-0000-000000000000"
#   metastore_id = "00000000-0000-0000-0000-000000000000"
#   workspace_id = "0000000000000000"
# }
