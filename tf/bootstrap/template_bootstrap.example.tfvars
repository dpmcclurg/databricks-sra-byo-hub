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
azure_devops_project_name      = "my-ado-project" # must match azure_devops_project_name in account-admin-federation

# --- Account-admin identity ---
# Not configured in bootstrap. The account plane authenticates as a dedicated Databricks account service principal via
# OAuth token federation, set up ONCE per landing zone by a human account admin (see tf/account-admin-federation and the
# Account Admin OAuth Federation spec). The SP's client ID is set in the SPOKE var file as account_admin_client_id.

# --- tfstate storage (this layer creates it) ---
tfstate_storage_account_name = "sttfstateprod" # 3-24 lowercase alphanumeric, globally unique
# bootstrap_resource_group_name = "rg-cicd-bootstrap"   # optional; this is the default
# create_bootstrap_resource_group = true   # default. true (human-run): this layer creates the RG. Set false for the CI
#                                          # model, where the RG pre-exists to hold the foundational UAMI (see README).

# --- Environments served by THIS subscription ---
# NON-PROD example (dev + test). For the PROD subscription, use a single prd entry instead.
# environments = {
#   dev = {
#     resource_suffix              = "dbx-dev"
#     platform_service_connection  = "sc-dev-platform"
#     workspace_service_connection = "sc-dev-workspace"
#     # If provisioner does not own both peering halves, remove this block and set create_hub_peering = false in root (spoke/workspace) tfvars
#     hub_virtual_network_ids = [
#       # "/subscriptions/<nonprod-sub>/resourceGroups/rg-hub-dev/providers/Microsoft.Network/virtualNetworks/vnet-hub-dev-eastus2",
#     ]
#   }
#   test = {
#     resource_suffix              = "dbx-test"
#     platform_service_connection  = "sc-test-platform"
#     workspace_service_connection = "sc-test-workspace"
#     # If provisioner does not own both peering halves, remove this block and set create_hub_peering = false in root (spoke/workspace) tfvars
#     hub_virtual_network_ids = [
#       # "/subscriptions/<nonprod-sub>/resourceGroups/rg-hub-test/providers/Microsoft.Network/virtualNetworks/vnet-hub-test-eastus2",
#     ]
#   }
# }

# --- PROD subscription instance would instead use (single prd entry) ---
environments = {
  prd = {
    resource_suffix              = "dbx-prod"
    platform_service_connection  = "sc-prd-platform"
    workspace_service_connection = "sc-prd-workspace"  
    # If provisioner does not own both peering halves, remove this block and set create_hub_peering = false in root (spoke/workspace) tfvars
    hub_virtual_network_ids = [
      "/subscriptions/<prod-sub>/resourceGroups/rg-hub-prd/providers/Microsoft.Network/virtualNetworks/vnet-hub-prd-example",
    ]
  }
}
