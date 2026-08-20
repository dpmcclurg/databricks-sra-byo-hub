# account-admin-federation — one-time account-SP setup (per landing zone)

Creates the dedicated **Databricks account service principal** the spoke's account-host provider authenticates as, and
its **OAuth token federation policy** trusting the spoke pipeline. Replaces the old Azure account-admin UAMI: the account
plane is now Databricks-native, secret-free, and needs no Azure identity, no ARM service connection, and no Reader grant.

See the *Account Admin OAuth Federation* spec for the full design. For where this fits in the overall deployment, see the
master sequence in the [repo root README's "Deployment order"](../../README.md#deployment-order) — this step is
**independent of bootstrap** and just needs to be done before the spoke pipeline runs.

## When and who
Run **once per landing zone**, by a **human Databricks account admin**, locally via `az login` (the provider uses
`auth_type = "azure-cli"`). Creating an account SP and a federation policy are account-admin operations, so the spoke
pipeline can't bootstrap its own trust — this is the deliberate manual step.

## Run
```bash
az login                                   # as a Databricks account admin
cd tf/account-admin-federation
cp terraform.tfvars.example prod.tfvars    # then fill in
terraform init
terraform apply -var-file prod.tfvars
terraform output account_admin_client_id   # -> put in the SPOKE var file as account_admin_client_id
```

## Then — two manual follow-ups (not managed here)
1. **Make the SP an account admin.** In the Databricks **account console**, add the new service principal to the account
   `admins` group. (Kept manual on purpose — Terraform does not manage account-admin membership.)
2. **Set the client ID in the spoke.** Put the `account_admin_client_id` output into the spoke env var file
   (`tf/env/<env>.tfvars`). The spoke pipeline maps `SYSTEM_ACCESSTOKEN` and the account-host provider does the rest.

## Notes
- The federation **subject is pipeline-scoped** (`p://<org>/<project>/<pipeline>`). Renaming the spoke pipeline breaks
  the trust; update `spoke_pipeline_name` and re-apply. One policy covers all **stages** of that pipeline.
- A separate landing zone = a separate pipeline = its own SP + policy (run this config again with its own var file).
- Issuer is `https://vstoken.dev.azure.com/<org-id>` (the pipeline's built-in OIDC) — unrelated to the Entra issuer used
  by ARM service connections, and its subject is stable, so this trust is safely Terraform-managed.

## Prerequisite for the spoke

The spoke's account-admin-gated resources (`databricks_metastore_assignment`, `databricks_mws_ncc_binding`,
`databricks_workspace_network_option`, and the NCC private-endpoint rule) authenticate as this SP. Three things must be
true before the spoke runs, or those resources fail the OIDC token exchange with `invalid_client` / "not a member of
account":

1. This layer is applied — the SP **and** its federation policy exist (the policy is what the exchange validates against).
2. The SP is a member of the account `admins` group.
3. `account_admin_client_id` in the spoke var file is this SP's Application ID (from `terraform output account_admin_client_id`).
