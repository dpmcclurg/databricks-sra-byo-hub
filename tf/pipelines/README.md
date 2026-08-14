# Azure DevOps pipelines

Two pipelines, one reusable job template, for the platform and spoke layers. Both authenticate as a per-environment
UAMI through a Workload Identity Federation service connection — no secrets. The UAMIs, their federated credentials, and
the state account are provisioned by the [bootstrap layer](../bootstrap/README.md); read that first for how the
identities and service connections line up.

| File | Purpose |
| --- | --- |
| [`azure-pipelines-platform.yml`](azure-pipelines-platform.yml) | Platform layer (shared Key Vault + CMKs). Triggers on `tf/platform/**`. One stage per environment. |
| [`azure-pipelines-spoke.yml`](azure-pipelines-spoke.yml) | Spoke layer (workspace + VNet + catalog). Triggers on `tf/**`, excluding the platform, bootstrap, and pipeline paths. One stage per environment. |
| [`templates/terraform-layer.yml`](templates/terraform-layer.yml) | Reusable job: install Terraform → init with a CI-only backend → validate → plan → optional apply. |

## Setup in Azure DevOps

1. **Create the service connections** the stages reference (`sc-<env>-platform`, `sc-<env>-workspace`). The name must
   match the `*_service_connection` value the bootstrap layer used, byte-for-byte — the UAMI's federated-credential
   subject encodes it, and a mismatch fails the OIDC exchange. See the bootstrap README.
2. **New pipeline** → Azure Repos Git → your repo → **Existing Azure Pipelines YAML file** → point at each YAML → Save.
3. On the first run, **Permit** the pipeline to use each service connection when ADO prompts.
4. Pipelines default to `action: plan`; choose `apply` explicitly to converge. CI triggers on push run `plan` only.

Run the **platform** layer for an environment before the **spoke** layer for that environment — the spoke consumes the
platform's CMK outputs.

## Notes

**Terraform install.** The template downloads the pinned Terraform from `releases.hashicorp.com` in a script step rather
than using the `TerraformInstaller` marketplace task, so no organization-level extension is required. It fetches the
`linux_amd64` build — correct for the hosted `ubuntu-latest` agent and self-hosted Linux; adjust the arch for a non-Linux
self-hosted agent.

**Terraform ≥ 1.12 required** (pinned to 1.15.8). The spoke `tests/*.tftest.hcl` use the top-level `test {}` block, which
`terraform validate` parses and which only exists in Terraform 1.12+. `versions.tf` already permits it (`~> 1.11`).

## Per-environment configuration

Each stage passes `varFile: env/<env>.tfvars`, and the template injects the remote-state backend via `-backend-config`
key/value pairs (so the `env/<env>.backend.hcl` files are for local `terraform init` — CI supplies the same coordinates
inline). Copy the `env/*.example` templates to real `env/<env>.tfvars` / `env/<env>.backend.hcl` and fill them in.

The real `env/*.tfvars` and `env/*.backend.hcl` are **git-ignored** in this repo; only the `*.example` templates are
committed. [HashiCorp advises ignoring variable definition files that contain sensitive
values](https://developer.hashicorp.com/terraform/language/values/variables); authentication here is secretless
(WIF/UAMI), so these files hold only non-sensitive identifiers and would be safe to commit — this repo keeps them ignored
anyway as a public-repo default. If you run it privately and prefer them in version control, add scoped `!` exceptions in
`.gitignore`. Never put a real secret in a tfvars either way — inject it at runtime as a `TF_VAR_*` env var (from an ADO
variable group linked to Key Vault, or the `AzureKeyVault@2` task) and mark the Terraform variable `sensitive = true`.

## Adjusting the environment list

The pipelines ship with `dev` and `test` stages. To add another environment, add a stage that references that
environment's service connection, its `env/<env>.tfvars`, and a distinct backend state key, and point
`tfstateStorageAccount` at the state account its bootstrap created. Each environment keeps its own state key so
environments never share state.
