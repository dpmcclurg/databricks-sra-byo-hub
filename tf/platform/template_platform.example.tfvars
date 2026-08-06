# Platform layer: the shared Key Vault and CMKs for one subscription, in one region.
#
# Apply this ONCE before any spoke workspace. Then run
#   terraform output -raw spoke_tfvars_snippet
# and paste the result into each spoke's var file in tf/.

subscription_id = "00000000-0000-0000-0000-000000000000"

# Must match the location of every spoke workspace served by this vault. A vault cannot serve a workspace in another
# region, so a second region needs a second instance of this configuration and its own state.
location = "eastus2"

resource_suffix = "dbx-prod"

# Explicit, deterministic names are strongly preferred for this shared vault. With a generated name, losing this state
# would produce a second empty vault while every spoke still points at the first one's keys - orphaned but alive, so
# nothing fails loudly. Vault names are globally unique, 3-24 chars.
key_vault_name  = "kv-dbx-prod-eastus2"
key_name_prefix = "kvk-dbx-prod"

# Defaults to rg-<resource_suffix>-security
# security_resource_group_name = "rg-dbx-prod-security"

# Deploy into a centrally-governed resource group instead of creating one
# create_security_resource_group        = false
# existing_security_resource_group_name = "rg-prod-security"

tags = {
  owner       = "user@example.com"
  environment = "prod"
}
