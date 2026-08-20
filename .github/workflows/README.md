# GitHub Actions workflows

Two caller workflows and one reusable job, for the platform and spoke layers — the GitHub counterpart to the
[Azure DevOps pipelines](../../tf/pipelines/README.md), deploying the **same** layers the same way. Both paths can
coexist; this is an alternative, not a replacement. Auth is **OIDC / workload identity federation** — no secrets. The
UAMIs, their GitHub federated credentials, and the state account come from the [bootstrap layer](../../tf/bootstrap/README.md)
(run it with `github_repository` set); read that first.

| File | Purpose |
| --- | --- |
| [`platform.yml`](platform.yml) | Platform layer (shared Key Vault + CMKs). Triggers on `tf/platform/**`. Jobs `dev` → `test`. `action`: `plan` \| `apply`. |
| [`spoke.yml`](spoke.yml) | Spoke layer (workspace + VNet + catalog). Triggers on `tf/**` excluding the platform, bootstrap, pipeline, and account-admin-federation paths. Jobs `dev` → `test`. `action`: `plan` \| `apply` \| `destroy`. |
| [`terraform-layer.yml`](terraform-layer.yml) | Reusable job: install Terraform → init with a CI-only backend → validate → plan → apply/destroy. Serialized per `(layer, env)` via `concurrency`. |

## Setup in GitHub

Full end-to-end setup (create Environments, wire variables, run and troubleshoot) is in the deployment runbook. In brief:

1. **Create four GitHub Environments** — `dev-platform`, `test-platform`, `dev-workspace`, `test-workspace`. The name is
   encoded in the OIDC federated-credential subject, so it must match byte-for-byte across the workflow caller, the
   GitHub Environment, and the `tf/bootstrap` + `tf/account-admin-federation` subjects — to use your own names, change
   all of them together (see the deployment runbook, "Choosing your own environment names"). On each, set **Variables**
   (not Secrets) `ARM_CLIENT_ID`,
   `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`. `ARM_CLIENT_ID`/`ARM_TENANT_ID` come from the bootstrap
   `github_environments` output; `ARM_SUBSCRIPTION_ID` is the landing-zone subscription (`az account show`).
2. **Prerequisites for the spoke's account-admin resources:** the `account-admin-federation` layer applied with
   `github_repository` set, the account SP in the account `admins` group, and `account_admin_client_id` set in each
   `env/<env>.tfvars` — the same three preconditions as the ADO path. The account-host provider authenticates via
   `github-oidc` (set through `TF_VAR_account_admin_auth_type` in the reusable workflow) with `audience` = the Databricks
   account ID.
3. **Approvals (optional):** add **required reviewers** to an environment to gate `apply`/`destroy`. Note GitHub gates
   the whole job entering the environment, so reviewers also pause `plan` runs into that environment.
4. **Run:** `push` to `main` runs `plan` only (never applies). Trigger `apply`/`destroy` via **Run workflow**
   (`workflow_dispatch`) or `gh workflow run <platform|spoke>.yml -f action=<plan|apply|destroy>`.

Run the **platform** layer for an environment before the **spoke** layer for that environment — the spoke consumes the
platform's CMK outputs. The **spoke** `destroy` runs as the workspace UAMI and does not touch the shared platform vault;
the **platform** workflow has no `destroy` (its keys carry `prevent_destroy` — use `tf/platform/destroy.sh`).

## Per-environment configuration

Each job passes `var-file: env/<env>.tfvars`, and the reusable workflow injects the remote-state backend via
`-backend-config` key/value pairs. Copy the `env/*.example` templates to real `env/<env>.tfvars` and fill them in — the
same var files the ADO path uses (auth type is supplied by the workflow, not the var file, so the files are identical
across both CI paths). Only `dev` + `test` are wired; see the runbook to add `prd`.
