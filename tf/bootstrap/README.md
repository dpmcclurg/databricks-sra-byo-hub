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

## Prerequisite: the foundational identity (manual, once per org)

This layer is itself run by a UAMI — the **foundational CI/CD identity** — created **once, by hand**, because something
has to exist before any pipeline can authenticate. This is the only manual identity step.

1. **Create the UAMI** in the Azure portal (or CLI): `id-cicd-foundational`, in a new RG `rg-cicd-bootstrap`.
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
   | Storage Blob Data Contributor | resource group | create the tfstate container during apply, then migrate bootstrap state into it. RG-scoped so it exists before the account does and inherits down to it — granting it here avoids a first-apply 403 on the container |
3. **Create an Azure DevOps service connection** of type *Azure Resource Manager* → **Workload Identity federation
   (manual)**. Name it e.g. `sc-cicd-bootstrap`. The manual flow shows an **Issuer** and **Subject** — leave the screen
   open.
4. **Add a federated credential to the UAMI** matching that service connection:
   ```bash
   az identity federated-credential create \
     --name adodeploy-bootstrap \
     --identity-name id-cicd-foundational \
     --resource-group rg-cicd-bootstrap \
     --issuer   "<provided in service connection panel>" \
     --subject  "<provided in service connection panel>" \
     --audiences "api://AzureADTokenExchange"
   ```
   Save the service connection (Azure DevOps validates the federated credential on save).

The foundational identity then runs this bootstrap layer via a pipeline (or you run it locally as yourself for the very
first apply — see below).

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

## Running bootstrap locally: grant yourself the storage data role first

The tfstate storage account this layer creates is **AAD-only** (`shared_access_key_enabled = false`), and the provider
is set with `storage_use_azuread = true` so it uses your AAD identity for storage data-plane calls rather than an
account key. Creating the state **container** is a data-plane operation, so the identity running the apply needs a
storage *data* role — and this is a role you likely do **not** already have, even as a subscription Owner:

> **Owner does not grant blob data access.** `Owner`/`Contributor` are control-plane roles with no `DataActions`, so
> they cannot read or write blobs. Without a data role the apply fails at the container with
> `403 KeyBasedAuthenticationNotPermitted` (the provider fell back to key auth because it has no AAD blob access). The
> foundational UAMI is granted `Storage Blob Data Contributor` by this layer, so CI is unaffected — this gap only bites a
> local run as yourself.

**Grant it up front, scoped to the bootstrap RG**, as part of the manual prerequisite (it is the last row of the roles
table above). The RG exists before the storage account does, and the role inherits down to the account when this layer
creates it — so the first apply just works, with no failure to recover from:

```bash
# Your object ID: az ad signed-in-user show --query id -o tsv
az role assignment create \
  --assignee "<your-object-id>" \
  --role "Storage Blob Data Contributor" \
  --scope "$(az group show -n rg-cicd-bootstrap --query id -o tsv)"
# RBAC is eventually consistent - allow ~1-2 minutes before the first apply.
```

> **If you already ran the apply and hit the 403**, the account now exists, so grant the same role on the account (or
> the RG, as above) and re-apply — the run picks up at the container:
> ```bash
> az role assignment create \
>   --assignee "<your-object-id>" \
>   --role "Storage Blob Data Contributor" \
>   --scope "$(az storage account show -n <tfstate-account> -g rg-cicd-bootstrap --query id -o tsv)"
> terraform apply -var-file <your-var-file>
> ```

---

## Run order

```
# 0. Manual: foundational identity + its federated credential (above).

# 1. Bootstrap (per subscription). First apply uses LOCAL state because this layer creates the state account.
cd tf/bootstrap
cp template_bootstrap.example.tfvars bootstrap-nonprod.tfvars   # then fill in
terraform init
terraform apply -var-file bootstrap-nonprod.tfvars
#    Then migrate bootstrap's own state into the account it just created:
#    uncomment the backend block in versions.tf and:
terraform init -migrate-state \
  -backend-config="resource_group_name=rg-cicd-bootstrap" \
  -backend-config="storage_account_name=sttfstatenonprod" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=bootstrap.tfstate" \
  -backend-config="use_azuread_auth=true"

# 2. Read the outputs — resource group names go into the platform/spoke var files:
terraform output environments

# 3. Create the Azure DevOps service connections (WIF manual), matching the *_service_connection names in your
#    var file. The federated credentials on the UAMIs already exist (this layer made them), so save should validate.

# 4. Pre-resolve the Azure Databricks enterprise app object ID ONCE, as a user with Entra directory read, and put it in
#    each platform var file as databricks_service_principal_object_id (see the Graph note above). This keeps the
#    platform UAMI free of any Entra permission.
az ad sp show --id 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query id -o tsv

# 5. Platform layer, per env — run from the pipeline (as the platform UAMI) or locally as yourself.
# 6. Spoke layer, per env — after the platform layer for that env.
```

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
