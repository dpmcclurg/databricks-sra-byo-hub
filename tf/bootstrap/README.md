# Bootstrap layer — CI/CD identities and shared state

This layer creates the **user-assigned managed identities (UAMIs)** that every pipeline authenticates as, plus the
storage account that holds all layers' Terraform state, for **one subscription**. It exists to make the platform and
spoke layers deployable from Azure DevOps with **no secrets** — each layer runs as a UAMI federated to an Azure DevOps
service connection via Workload Identity Federation (WIF).

## The three layers

```
bootstrap/   (this)   →  per-env UAMIs, their federated creds, RBAC, and the tfstate storage account
platform/             →  shared Key Vault + CMKs, run AS the per-env platform UAMI
tf/ (spoke)           →  Databricks workspace + VNet + catalog, run AS the per-env workspace UAMI
```

Run **one bootstrap instance per subscription**:

| Subscription | `environments` | tfstate account (example) |
| --- | --- | --- |
| NON-PROD | `{ dev, test }` | `sttfstatenonprod` |
| PROD | `{ prd }` | `sttfstateprod` |

Each environment gets a **platform UAMI** (in its `rg-<suffix>-security`) and a **workspace UAMI** (in its
`rg-<suffix>`), so identities are co-located with the resources they provision. The platform and spoke layers then run
with `create_*_resource_group = false`, pointing at the resource groups this layer created.

---

## Prerequisite (human-run model)

By default this layer is run by **a human with Owner on the subscription**, via `az login` — there is **no foundational
identity to create**. With `create_bootstrap_resource_group = true` (the default) this layer creates the bootstrap RG
(`rg-cicd-bootstrap`) and the tfstate account itself; the first apply uses local state, then you migrate bootstrap's own
state into the account it just created (see **Run order**). That is the entire prerequisite: Owner + `az login`.

> [!WARNING]
> On subscriptions that grant Owner with an ABAC **constrained-role-assignment** condition (no delegating privileged
> admin roles), the **Role Based Access Control Administrator** grants this layer makes to the per-env UAMIs (see
> `rbac.tf`) fail with `AuthorizationFailed … ABAC condition that is not fulfilled`. Even Owner can't delegate a
> privileged role if their own grant carries that condition. Get those assignments permitted at the target RG scopes (or
> an unconstrained User Access Administrator) before running bootstrap.

To run bootstrap from an Azure DevOps pipeline instead of by hand, see **Upgrading to CI/CD** below.

---

## Upgrading to CI/CD

To run bootstrap (and the other layers) from Azure DevOps rather than by hand, add a **foundational CI/CD identity** — a
UAMI the bootstrap pipeline authenticates as, created **once, by hand**, because something has to exist before any
pipeline can authenticate. Set **`create_bootstrap_resource_group = false`** so this layer *reads* the bootstrap RG
(which now pre-exists to hold that UAMI) as a data source instead of creating it.

1. **Create the RG + UAMI**:
   ```bash
   az group create -n rg-cicd-bootstrap -l eastus2
   az identity create -g rg-cicd-bootstrap -n id-cicd-foundational
   ```
2. **Grant it subscription-scoped roles** (repeat per subscription it bootstraps — NON-PROD and PROD):
   | Role | Scope | Why |
   | --- | --- | --- |
   | Managed Identity Contributor | subscription | create the per-env UAMIs |
   | Role Based Access Control Administrator | subscription | assign the per-env UAMIs their roles |
   | Contributor | subscription | create RGs + the tfstate storage account |
   | Storage Blob Data Contributor | resource group | migrate bootstrap's own state into the tfstate account (a data-plane blob write). RG-scoped so it covers the account this layer creates |
3. **Create an Azure DevOps service connection** of type *Azure Resource Manager* → **Workload Identity federation
   (manual)**. Name it e.g. `sc-cicd-bootstrap`. The manual flow shows an **Issuer** and **Subject** — leave the screen
   open.
4. **Add a federated credential to the UAMI** matching that service connection, copying the values the dialog shows:
   ```bash
   az identity federated-credential create \
     --name adodeploy-bootstrap \
     --identity-name id-cicd-foundational \
     --resource-group rg-cicd-bootstrap \
     --issuer   "<Issuer from the service connection panel>" \
     --subject  "<Subject identifier from the service connection panel>" \
     --audiences "api://AzureADTokenExchange"
   ```
   Save the service connection (Azure DevOps validates the federated credential on save).

> [!IMPORTANT]
> Copy the Issuer and Subject from the connection dialog verbatim. Azure DevOps issues WIF tokens from the Entra issuer
> (`https://login.microsoftonline.com/<tenant>/v2.0`) with an opaque subject that embeds the connection's GUID, so the
> federated credential must carry those exact values. This applies to every WIF connection here (foundational, platform,
> workspace, account-admin).

The foundational identity then runs this bootstrap layer via a pipeline. Set `create_bootstrap_resource_group = false` in
the bootstrap var file so the pre-existing RG is read rather than recreated.

---

## How Workload Identity Federation maps to a UAMI

A UAMI can hold **federated identity credentials** exactly like an app registration can. When a
pipeline runs:

```
1. AzureCLI@2 (azureSubscription: <service-connection>) asks Azure DevOps for an OIDC token:
     iss = https://vstoken.dev.azure.com/<organization-id>
     sub = sc://<org-name>/<project-name>/<service-connection-name>
     aud = api://AzureADTokenExchange
2. Entra ID finds the UAMI whose federated credential matches (iss, sub, aud) EXACTLY,
   and returns an Entra access token for THAT UAMI.
3. The az CLI is now logged in as the UAMI; Terraform's providers use it (use_oidc + ARM_* vars).
```

The three fields must match byte-for-byte between the **service connection** and the **UAMI's federated credential**.
This layer builds them from `azure_devops_organization_id`, `azure_devops_organization_name`,
`azure_devops_project_name`, and each env's `*_service_connection` names:

| Field | Value |
| --- | --- |
| Issuer | `https://vstoken.dev.azure.com/<organization-id>` |
| Subject | `sc://<org-name>/<project-name>/<service-connection-name>` |
| Audience | `api://AzureADTokenExchange` |

> A UAMI supports up to ~20 federated credentials; one per service connection here is well within that.

---

## RBAC each UAMI receives (from `rbac.tf`)

**Platform UAMI** (`id-<suffix>-platform`):

| Role | Scope | Why |
| --- | --- | --- |
| Contributor | security RG | create the vault, private endpoint, DNS zone |
| Role Based Access Control Administrator | security RG | grant the Azure Databricks control plane the CMK Crypto role |
| Storage Blob Data Contributor | tfstate SA | platform layer's remote state |

**Workspace UAMI** (`id-<suffix>-workspace`):

| Role | Scope | Why |
| --- | --- | --- |
| Contributor | spoke RG | workspace, VNet, catalog |
| Role Based Access Control Administrator | spoke RG | self-grant workspace Contributor; grant workspace identities the CMK role |
| Key Vault Data Access Administrator | security RG (the vault) | cross-layer: grant workspace-storage + Disk Encryption Set identities the CMK Crypto role on the shared vault |
| Network Contributor | each hub VNet | create the spoke half of the peering (one grant per hub; hub differs by region / prod-vs-nonprod) |
| Storage Blob Data Contributor | tfstate SA | spoke layer's remote state |
| _Databricks Workspace Storage PE Approver_ (custom role) | subscription | approve the private endpoints to the workspace **default storage** account when `secure_workspace_default_storage` is on |

> **Why the storage-PE-approver role is subscription-scoped — and why it is still tight.** With
> `secure_workspace_default_storage` enabled (the default), the spoke creates private endpoints to the workspace default
> storage account. Auto-approving them needs
> `Microsoft.Storage/storageAccounts/PrivateEndpointConnectionsApproval/action` **on that account**, which lives in the
> Databricks-**managed** resource group — a linked-scope check the spoke-RG Contributor does not satisfy (the apply fails
> with `LinkedAuthorizationFailed`). The managed RG's name is generated by Azure and unknown until the workspace exists,
> so the grant cannot be scoped to that RG here. Rather than assign a broad built-in role (Storage Account Contributor)
> subscription-wide, `rbac.tf` defines a **custom role carrying only the four storage private-endpoint actions** and
> assigns it at subscription scope: the UAMI can approve storage private endpoints anywhere in the subscription but has
> no storage data access, no key management, and cannot create or delete accounts. If you disable
> `secure_workspace_default_storage`, this grant is unnecessary.

> **No UAMI needs Entra directory read — pre-resolve one value instead.** The platform layer looks up the Azure
> Databricks enterprise app's object ID via the `azuread` provider, which needs Microsoft Entra directory-read
> (Directory Readers). **None of the three identities should hold that**, and the design does not grant it:
> - Directory read is an **Entra** grant, not Azure RBAC. The bootstrap UAMI holds only Azure roles, so it **cannot**
>   grant it to the platform UAMIs — doing so would require the bootstrap identity to hold privileged Entra rights
>   (Privileged Role Administrator), which defeats the point of scoping these identities to subscription RBAC.
> - So a **human with directory read resolves the value once** and pins it as config; every UAMI then needs zero Entra
>   permissions:
>   ```bash
>   az ad sp show --id 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query id -o tsv
>   ```
>   Put the result in `databricks_service_principal_object_id` in each platform var file. The appId is constant across
>   tenants; only this object ID is tenant-specific (and stable). This is effectively **required for any UAMI/CI run**;
>   it is optional only for a local run as yourself, since your user account already has directory read.

---

## Unity Catalog access: privileges and greenfield bootstrap

The spoke catalog module creates a UC **storage credential, external location, and catalog**, each owned by an
account-level group (`catalog_owner_group`). These are run as the **workspace UAMI** — *not* as an account admin; the
account-plane resources are a separate identity (see [`../account-admin-federation`](../account-admin-federation)).

**Access model.** UC authorization is scoped to the **metastore/securable** (the "room" — grants decide what you may
do). Every metastore grant and securable-create is administered **through an attached workspace** (the "doorway" — the
control-plane API is workspace-routed; the workspace is the execution context, not the authorization boundary). No
workspace attached to the metastore ⇒ no doorway ⇒ metastore privileges cannot be granted yet.

**What the workspace UAMI needs** (account admin grants none of these — UC is a separate plane):
- `CREATE_STORAGE_CREDENTIAL` / `CREATE_EXTERNAL_LOCATION` / `CREATE_CATALOG` **on the metastore** — to create the securables.
- Membership in **`catalog_owner_group`** — the module sets `owner = catalog_owner_group`, so ownership transfers to the
  group at creation. The UAMI needs membership to keep using them mid-apply (e.g. creating the external location on the
  just-created, group-owned credential) and to manage them on re-runs. Both are pinned to the SP — re-add after a UAMI recreate.

### Steady state (a workspace is already attached to the metastore)

A metastore admin grants the workspace UAMI `CREATE_STORAGE_CREDENTIAL` / `CREATE_EXTERNAL_LOCATION` / `CREATE_CATALOG`
on the metastore (via the account console, the Databricks CLI, or a `databricks_grant` in a UC-plane config), and the
UAMI is added to `catalog_owner_group` — set the same group in the spoke var file. The grant is workspace-routed, so it
is administered through any workspace already attached to the metastore. This is a Databricks-plane operation, kept out
of bootstrap, which stays a pure Azure-plane layer.

### Greenfield (the first workspace on a brand-new metastore)

No workspace exists to grant `CREATE_*` through, so bootstrap the first spoke with a temporary metastore-admin elevation.
Keep two distinct groups:

| Group | Role | UAMI membership |
|---|---|---|
| metastore admins (e.g. `dbx-metastore-admins`) | metastore admin (settable without a workspace) | **temporary** — greenfield only |
| `catalog_owner_group` (e.g. `dbx-owners`) | owns the securables | **permanent** |

1. Make a metastore-admin **group** the metastore admin; add the workspace UAMI to it (allow a few minutes to propagate).
2. Add the workspace UAMI to `catalog_owner_group`.
3. Run the spoke — as metastore admin the UAMI creates the securables in a single pass; `owner = catalog_owner_group` transfers ownership.
4. **Remove** the workspace UAMI from the metastore-admin group.
5. A metastore admin grants the UAMI `CREATE_*` (now that a workspace is attached) for the durable least-privilege state.

Keep the two groups separate: if `catalog_owner_group` were the metastore admin, the UAMI's permanent owner-group
membership would make it a permanent metastore admin. Only the first workspace per metastore needs steps 1/3/4 — once any
workspace is attached, later UAMIs just get `CREATE_*`.

---

## Blob-data access for the state migrate

The tfstate storage account this layer creates is **AAD-only** (`shared_access_key_enabled = false`), with the provider
set to `storage_use_azuread = true`. The state container is created through the management plane (the
`azurerm_storage_container` resource uses `storage_account_id`), so the first apply completes with `Owner` alone.
Migrating this layer's state into the account afterward is a data-plane blob write, which requires
`Storage Blob Data Contributor` on the account — a role `Owner`/`Contributor` do not include (they carry no
`DataActions`).

Order: **apply first, then grant the role on the created account, then migrate.**

```bash
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show -n <tfstate-account> -g rg-cicd-bootstrap --query id -o tsv)"
```

RBAC is eventually consistent — allow a few minutes for the grant to propagate, then uncomment the `backend "azurerm"`
block in `versions.tf` and migrate the local state into the account (answer `yes` at the copy prompt):

```bash
terraform init -migrate-state \
  -backend-config="resource_group_name=rg-cicd-bootstrap" \
  -backend-config="storage_account_name=<tfstate-account>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=bootstrap.tfstate" \
  -backend-config="use_azuread_auth=true"
```

A `403 AuthorizationPermissionMismatch` on the migrate means the grant has not propagated to your identity yet — wait
and retry (no re-login needed; RBAC is evaluated server-side).

The foundational UAMI is granted this role by the layer, so CI is unaffected. If a run reports `403` at the container
step (an older provider on the data-plane container path), grant the role first and re-apply.

---

## Run order

> The master end-to-end sequence across all layers (network → bootstrap ∥ account-admin federation → platform → spoke)
> lives in the [repo root README's "Deployment order"](../../README.md#deployment-order). This section is the detailed
> bootstrap runbook. Bootstrap and account-admin federation are independent (see the note at step 2b below).
>
> This runbook assumes you run **bootstrap and account-admin federation locally, as yourself** (`az login`), so both use
> **local** state. Moving bootstrap's state to the shared remote backend is a separate step covered in
> [Blob-data access for the state migrate](#blob-data-access-for-the-state-migrate); the platform and spoke layers run
> from the pipeline against that backend.

**0. Prerequisites.** In the default human-run model, all you need is `Owner` on the subscription and `az login` — no
foundational identity. (In the CI model you create the foundational identity first and set
`create_bootstrap_resource_group = false` — see [Upgrading to CI/CD](#upgrading-to-cicd).)

**1. Bootstrap the subscription (locally, as yourself).** The backend block in `versions.tf` stays commented, so this
apply uses **local** state — the layer creates the state account, so there is nothing remote to write to yet.
`create_bootstrap_resource_group` defaults to `true`, so the layer creates `rg-cicd-bootstrap` itself; do not create it
by hand.

```bash
az login
cd tf/bootstrap
cp template_bootstrap.example.tfvars bootstrap-nonprod.tfvars   # then fill in
terraform init                                                  # backend commented -> local state
terraform apply -var-file bootstrap-nonprod.tfvars             # creates rg-cicd-bootstrap, the tfstate account + container, per-env RGs, UAMIs, RBAC
```

To move this local state into the account it just created (needed for CI, optional for local-only use), grant yourself
blob-data access and migrate — see [Blob-data access for the state migrate](#blob-data-access-for-the-state-migrate).

**2. Read the outputs.** The resource group names go into the platform/spoke var files:

```bash
terraform output environments
```

**2b. Account-admin federation — independent of bootstrap, any time before the spoke.** The account plane authenticates
as a dedicated Databricks **account** service principal via OAuth token federation — **not** an Azure identity — so
bootstrap creates nothing for it and this is not gated on the steps above (run it before, after, or in parallel). Run it
once per landing zone, locally as a Databricks account admin (local state):

```bash
az login   # as a Databricks account admin
cd tf/account-admin-federation
cp terraform.tfvars.example prd.tfvars   # databricks_account_id, org/project, spoke_pipeline_name
terraform init && terraform apply -var-file prd.tfvars
terraform output account_admin_client_id   # the SP's Application ID
```

Then **add the SP to the account `admins` group by hand** and set `account_admin_client_id` in the spoke var file to
this SP's Application ID (not another SP grabbed from the console) — otherwise the spoke fails with `invalid_client` /
"not a member of account". Must be done before the spoke (step 6). See [`tf/account-admin-federation`](../account-admin-federation)
for details.

**3. Create the Azure DevOps service connections** (WIF manual), matching the `*_service_connection` names in your var
file — one per UAMI (e.g. `sc-<env>-platform`, `sc-<env>-workspace`). In each connection dialog Azure DevOps shows an
Issuer and Subject; add a federated credential to the matching UAMI using those values verbatim (Azure DevOps issues
Entra-issuer tokens; see [Upgrading to CI/CD](#upgrading-to-cicd)), then save the connection:

```bash
az identity federated-credential create --name adodeploy-<env>-platform \
  --identity-name id-<suffix>-platform --resource-group <platform-rg> \
  --issuer "<Issuer>" --subject "<Subject>" --audiences "api://AzureADTokenExchange"
az identity federated-credential create --name adodeploy-<env>-workspace \
  --identity-name id-<suffix>-workspace --resource-group <spoke-rg> \
  --issuer "<Issuer>" --subject "<Subject>" --audiences "api://AzureADTokenExchange"
```

**4. Pre-resolve the Azure Databricks enterprise app object ID once**, as a user with Entra directory read, and put it in
each platform var file as `databricks_service_principal_object_id` (see the Graph note above). This keeps the platform
UAMI free of any Entra permission.

```bash
az ad sp show --id 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query id -o tsv
```

**5. Platform layer, per env** — run from the pipeline (as the platform UAMI) or locally as yourself.

**6. Spoke layer, per env** — after the platform layer for that env.

In the platform/spoke var files, set `create_*_resource_group = false` and the `existing_*` RG names to the bootstrap
outputs. The pipelines that run steps 5–6 (and how to set them up in Azure DevOps) are documented in
[`../pipelines/README.md`](../pipelines/README.md).

---

## Local testing (Option A: personal-identity passthrough)

You do **not** impersonate a UAMI locally — a laptop can't natively assume one. Instead, run the layers as **yourself**
via `az login`. Because auth is ambient (`data.azurerm_client_config.current` = whoever is logged in), the code path is
identical to CI; you simply become the provisioner and workspace admin.

Keep two var-file profiles per environment:

| Profile | RG toggles | State | Use |
| --- | --- | --- | --- |
| `*.local.tfvars` | `create_*_resource_group = true` | local | throwaway local dev — you own disposable RGs |
| `*.tfvars` (CI) | `create_*_resource_group = false` + bootstrap RG names | remote (backend.hcl) | pipeline, shared envs |

```bash
az login
cd tf/platform
terraform apply -var-file dev.local.tfvars      # you are the provisioner; use_oidc defaults to false
```

`use_oidc` defaults to `false`, so nothing about the OIDC path interferes with a local `az login` run. The pipeline
passes `-var="use_oidc=true"`.

**Higher-fidelity option (B):** assign the env's actual UAMI to an Azure VM or Cloud Shell and run there with
`ARM_USE_MSI=true` — this exercises the real identity end-to-end without federation. Optional; Option A is the default.
