# Platform layer — shared Key Vault and CMKs

This configuration owns the customer-managed keys for the Azure Databricks workspaces in **one subscription, in one
region**, and the private path to them. Apply it once, before any spoke workspace. Spoke workspaces are deployed from
[`../`](../) — once per workspace, each with its own state — and consume this layer's outputs as inputs.

It holds no Databricks resources and declares no `databricks` provider.

```
rg-<suffix>-security          <- this configuration
├── kv-<name>                    shared vault, RBAC, public access disabled
│   ├── <prefix>-adb-services     managed services CMK
│   ├── <prefix>-adb-dbfs         DBFS root CMK
│   └── <prefix>-adb-disk         managed disk CMK
├── privatelink.vaultcore.azure.net   one zone, one VNet link per spoke
├── pe-<suffix>-kv                    one private endpoint to the vault
│   └── its NIC, created by Azure in this resource group
└── (optionally, each spoke's access connectors)

rg-<workspace>                <- created by the network team, BEFORE this configuration
├── the VNet, its subnets, and the hub peering
└── the workspace, catalog, and their private endpoints   <- ../ , once per workspace
```

The spoke resource group and VNet come first, built by the network team, because peering a spoke to the hub requires
permissions on the hub network that the Databricks provisioner does not hold. That is what makes it possible for this
layer to own the vault's private endpoint — the privatelink subnet already exists when this applies. The spoke
configuration then reuses that resource group rather than creating one.

Set `create_key_vault_private_endpoint = false` where the spoke VNet does not exist yet (for example a self-contained test
deployment where `../` creates its own network). CMK does not depend on the endpoint — see
[Vault network access](#vault-network-access).

## Why the vault is not in the spoke

Earlier revisions of this project created a vault **per spoke deployment**, in the spoke's own resource group. That was
the right shape when a deployment was one workspace in one state, and the reasoning is worth restating because two of its
three original justifications have been deliberately traded away here.

The constraint that has not changed: Azure Databricks requires the vault to be in the
[same region and Microsoft Entra ID tenant](https://learn.microsoft.com/en-us/azure/databricks/security/keys/cmk-managed-disks-azure/)
as every workspace it serves. A different subscription is allowed; a different region is not. So a single vault cannot
serve workspaces across regions — which inverts the usual hub-and-spoke intuition, since crossing subscriptions is fine
and crossing regions is not. **This configuration is therefore per subscription per region.** If PROD spans regions, it
needs one instance and one state per region.

What changed is ownership. A vault shared across workspaces cannot live in a resource group that any one workspace's
destroy would delete, and it has to outlive every workspace bound to it. So the vault moved out of the spoke entirely.

The two arguments given up, stated plainly:

- **Blast radius is no longer per-environment.** A per-spoke vault scoped a bad rotation, an accidental disable, or a
  revoke to one workspace. One shared key set means any of those breaks **every** workspace bound to this vault at once,
  and Azure Databricks documents lost keys as unrecoverable.
- **N states now mutate one vault.** The earlier design avoided several Terraform states writing to a single vault's
  authorization. That is now exactly what happens: each spoke creates role assignments on this vault for the identities
  it owns. RBAC makes it tolerable — the grant can be delegated with `Key Vault Data Access Administrator` scoped to the
  vault, so a spoke never needs broader rights on it.

What is bought in exchange: centralised key custody, and separation of duties between whoever operates the platform and
whoever operates a workspace.

If per-workspace isolation later matters more than central custody, the escape hatch is per-spoke key **sets** inside
this vault. Note that this couples to the RBAC scope decision below and the two should be revisited together.

## Authorization: RBAC, vault-scoped

The vault sets `rbac_authorization_enabled = true`. Access policies are vault-wide and accumulate one entry per identity,
which does not suit a vault written to by N spokes from N states.

Three role assignments of `Key Vault Crypto Service Encryption User` exist, all **scoped to the vault**:

| Principal | Granted by | For |
| --- | --- | --- |
| AzureDatabricks enterprise app (`2ff814a6-…`) | this layer | managed services unwrap, by the control plane |
| Workspace storage account identity | each spoke | DBFS root and managed services |
| Managed disk identity (the Disk Encryption Set) | each spoke | managed disk unwrap |

Vault scope is deliberate. The Key Vault RBAC guide states that *"assigning roles on individual keys, secrets and
certificates is not recommended"*, and its FAQ answers whether object-scope assignments isolate application teams with a
flat **No** — any administrative operation still needs vault-level permission. With one shared key set serving every
spoke, key-scoped assignments would add operational surface while isolating nothing. A test in
[`tests/mock_plan.tftest.hcl`](tests/mock_plan.tftest.hcl) asserts the scope so this cannot be quietly "tightened" later.

The honest cost: every spoke's storage identity can wrap/unwrap all three keys, including the managed disk key it has no
business touching.

## Vault network access

Public network access is disabled and the firewall denies by default, with one exception: **`bypass = "AzureServices"`**.
That bypass is what actually permits CMK. Neither unwrap call reaches the vault through a private endpoint — managed
services keys are unwrapped by the Databricks **control plane**, and managed disk keys by the **Disk Encryption Set** in
the workspace's managed resource group. Both sit outside every spoke VNet. Remove the bypass and clusters fail to start
with `KeyVaultAccessForbidden`.

It cannot be traded for an IP allowlist: the Disk Encryption Set has no published IP range. Nor for an NCC private
endpoint rule — Key Vault *is* a supported NCC resource type, but NCC covers serverless compute egress and neither CMK
caller is serverless compute.

The private endpoint this layer creates (`create_key_vault_private_endpoint`) is therefore **not** part of the CMK path.
It serves in-VNet data-plane callers — a Key Vault-backed secret scope from classic compute, an operator on a VM in the
VNet, or the key rotation below — and every spoke listed in `spoke_virtual_network_ids` resolves the vault through the one
shared `privatelink.vaultcore.azure.net` zone. One vault, one endpoint, one A-record; adding a spoke adds a VNet link
rather than a second zone.

> **Do not set this vault to "Secured by Perimeter."** Associating it with a Network Security Perimeter in enforced mode
> overrides the trusted-services bypass and breaks CMK for both key types. The Azure portal presents Secured by Perimeter
> as the *recommended* setting for resources in a perimeter, so it is easy to reach for — and with a shared vault, one
> click breaks every workspace at once, not one.

The keys are created as ARM resources (`Microsoft.KeyVault/vaults/keys` via `azapi_resource`) rather than with
`azurerm_key_vault_key`, so there is **no IP allowlist and no exception for the provisioner**. Per the Key Vault
networking docs, *"Key Vault firewall rules only apply to data plane operations. Control plane operations are not subject
to the restrictions specified in firewall rules."* The same asymmetry is why RBAC needs no data-plane role here:
`Microsoft.KeyVault/vaults/keys/write` is a control-plane Action carried by Key Vault Contributor, which has no
DataActions at all.

## Key rotation

**Rotation is a two-state, partly out-of-band operation.** ARM's `vaults/keys/write` explicitly *"does not create
subsequent versions, and does not update existing keys"*, so this configuration can create keys but cannot rotate them.
Rotation is a Key Vault data-plane operation, against a vault with public access disabled.

With one shared key set, this is a fleet-wide change-control event rather than a per-workspace chore.

1. **Rotate the key**, from a host inside a VNet linked to the vaultcore zone (which reaches it over this layer's private
   endpoint), or through the portal:
   ```bash
   az keyvault key rotate --vault-name <vault> --name <prefix>-adb-services
   ```
2. **Refresh this layer's record of the version.** `terraform apply` here re-reads the ARM response.
3. **Update every spoke.** Run `terraform output -raw spoke_tfvars_snippet`, paste into each spoke's var file, and apply
   each spoke. The key IDs are versioned because Databricks requires a specific version, never `latest`.
4. **Keep the old version available for 24 hours** after a managed services update — Azure Databricks documents this
   requirement explicitly. Do not delete it sooner.

`managed_disk_cmk_rotation_to_latest_version_enabled` is set on each workspace, so the Disk Encryption Set follows new
versions of the **managed disk** key on its own. Only managed services and DBFS root need step 3.

## Deploying

Per-environment config lives in `env/` — one `<env>.tfvars` and one `<env>.backend.hcl` per environment, so the single
root config here serves dev/test/prd with isolated remote state (a distinct state key per env). The `<env>.tfvars` set
`create_security_resource_group = false` and point at the resource group the bootstrap layer created. Real env files are
gitignored; the `*.example` files are the templates to copy.

```shell
cd tf/platform

# First time in this environment: uncomment the backend "azurerm" {} block in versions.tf, then:
terraform init -backend-config=env/prd.backend.hcl     # per-env remote state (bootstrap-created account)
terraform validate
terraform plan  -var-file=env/prd.tfvars
terraform apply -var-file=env/prd.tfvars

terraform output -raw spoke_tfvars_snippet             # paste into the spoke's env/<env>.tfvars platform_cmk block
```

For a throwaway **local** run (local state, self-created RG), skip the backend and use a `*.local.tfvars` with
`create_security_resource_group = true` instead — see the bootstrap README's local-testing note.

Set `key_vault_name` and `key_name_prefix` explicitly. The generated name embeds a random suffix, which is right for a
disposable per-workspace vault and wrong for a shared singleton: losing this state would produce a *second* empty vault
while every spoke still pointed at the first one's key URIs — orphaned but alive, so nothing would fail loudly.

**Use a versioned, locking remote backend.** See the commented block in [`versions.tf`](versions.tf). A local state file
is acceptable for a disposable spoke; it is not acceptable for the only record of a shared vault's identity.

### Permissions

| Need | Least-privilege role | Scope |
| --- | --- | --- |
| Create the resource group | `Contributor` | subscription, or pre-create the RG |
| Create the vault, set RBAC and the firewall | `Key Vault Contributor` | security RG |
| Create the three keys through ARM | `Key Vault Contributor` — `vaults/keys/write` is inside `Microsoft.KeyVault/*`. **No data-plane role, no access policy, no firewall exception.** | security RG |
| Create the AzureDatabricks role assignment | `Key Vault Data Access Administrator` — exists precisely to delegate the CMK roles, with an ABAC condition constraining which | the vault |
| Resolve the AzureDatabricks app | Entra directory read (`Application.Read.All` or Directory Readers) — **not** an Azure RBAC role | tenant |

> One caveat to test rather than assume. The RBAC guide says *changing* the permission model on an existing vault needs
> unrestricted `Microsoft.Authorization/roleAssignments/write`, and that a restricted `Key Vault Data Access
> Administrator` cannot do it. Creating a vault with RBAC already on should be plain `Microsoft.KeyVault/vaults/write`.
> If the first apply fails with an authorization error on the vault create, this is why — grant `User Access
> Administrator` on the security RG to bootstrap, and consider dropping back afterwards.

Where directory read is unavailable, pass `databricks_service_principal_object_id` explicitly to skip the Graph lookup.

## Tests

```shell
cd tf/platform
terraform init
terraform test
```

No deployed infrastructure, and — unlike the spoke suite — **no `az login`**, because `azuread` is mocked here. That is
also why the module accepts `databricks_service_principal_object_id`: mocking
`data.azuread_application_published_app_ids` is awkward, since its `result` is a map indexed by `["AzureDataBricks"]` and
an empty mock makes that index fail at plan time.

The runs use `command = apply` rather than `plan` because the role-assignment scope assertion compares two resource IDs,
which are not known until after apply. Every provider is mocked, so nothing is created.

## Destroying

```shell
cd tf/platform
./destroy.sh -var-file my-platform.tfvars
```

Use the wrapper, not `terraform destroy`. It guards three things:

1. **Live spokes.** Nothing in this state knows which workspaces reference the vault, so the script asks Azure directly
   and refuses if any workspace's CMK configuration points at this vault's URI. `--force` overrides, and then requires
   the vault name to be typed out.
2. **`prevent_destroy`** on the vault and all three keys means `terraform destroy` refuses outright. That friction is
   intentional; removing the lifecycle blocks is a deliberate edit, and the script will not do it for you.
3. **ARM cannot delete keys.** There is no DELETE verb for `Microsoft.KeyVault/vaults/keys` (`RESPONSE 405:
   DeleteNotSupported`) — deleting a key is only ever a data-plane operation. The script drops the keys from state, after
   backing it up, and lets the vault deletion remove them. Nothing is orphaned.

Afterwards the vault and keys are **soft-deleted, not gone**: purge protection is on and cannot be turned off, so they
stay recoverable for `soft_delete_retention_days` (default 90 here), and the name stays reserved for that whole window.
**The name cannot be reclaimed early** — with purge protection enabled `az keyvault purge` is refused until the retention
period elapses (that is the point of purge protection). Recovery is therefore the only way back before then:
`recover_soft_deleted_key_vaults` plus a specific order of operations — **use `./recover.sh`, not a plain re-apply** (see
the next section for why).

## Recovering from soft delete: use `recover.sh`

**A plain `terraform apply` does not recover this cleanly — it errors on the keys.** This is a genuine
order-of-operations trap, so recovery is scripted in [`recover.sh`](recover.sh).

Two prerequisites decide whether recovery even reaches the keys — get either wrong and it fails on the vault first:

- **Run as an identity that can recover a soft-deleted vault.** Detecting and recovering a soft-deleted vault is a
  **subscription-scoped** operation (`Microsoft.KeyVault/locations/<location>/deletedVaults`), not an RG-scoped one. The
  least-privilege deploy UAMI is `Key Vault Contributor` on the security RG only, so it **cannot** recover — with
  `recover_soft_deleted_key_vaults` set, the provider silently falls back to a plain create and the apply fails with a
  vault-level **409** (`a vault with the same name already exists in deleted state`). Recovery is therefore a **by-hand**
  operation run as a subscription-scoped `Key Vault Contributor` / `Contributor` / `Owner` — **not** something a pipeline
  can do. That 409 in a pipeline run is the symptom of a prior teardown having left this vault soft-deleted.
- **Init against the vault's remote state — first.** `recover.sh` operates on whatever backend this directory is
  initialised to. Run it in a checkout where the `backend "azurerm"` block is still commented and it recovers into a
  **local** `terraform.tfstate`, diverging from the pipeline's remote state; the next pipeline run then fails with
  `a resource with the ID ... already exists — to be managed via Terraform this resource needs to be imported into the
  State`, because the vault is live but absent from the state the pipeline reads. Uncomment the backend block and
  `terraform init -backend-config=env/<env>.backend.hcl` before recovering. (`recover.sh` warns if it detects local
  state.)

```shell
cd tf/platform
# uncomment the backend "azurerm" {} block in versions.tf, then point at the vault's remote state:
terraform init -backend-config=env/prd.backend.hcl
./recover.sh -var-file env/prd.tfvars
```

### Why a plain re-apply fails

Recovering a soft-deleted vault restores the vault **and every key inside it, with versions intact** — keys are not
recovered separately, and their names stay globally reserved while soft-deleted so they cannot be recreated (see the
[Azure Key Vault recovery docs](https://learn.microsoft.com/en-us/azure/key-vault/general/key-vault-recovery)). But the
keys were **dropped from Terraform state** on teardown (ARM cannot delete keys, so `destroy.sh` removes them from state
and lets the vault deletion take them — see the Destroying section). That combination traps a naive recovery from both
sides:

- **Plain `terraform apply`** recovers the vault (via `recover_soft_deleted_key_vaults`) and then, in the *same* apply,
  tries to **create** the three keys through ARM. They already exist in the just-recovered vault, so ARM returns a
  conflict and the apply fails. This is the error you hit if you "just re-apply".
- **`terraform import` first** does not work either: while the vault is still soft-deleted the keys are not live, so
  there is nothing to import yet.

### The order `recover.sh` performs

1. **Recover the vault only** — `terraform apply -target=module.vault.azurerm_key_vault.this`. Targeting just the vault
   triggers recovery without letting the same apply attempt to create the keys (the keys depend on the vault, not the
   other way round, so they are not pulled in).
2. **Import the now-live keys** into state — they exist in the recovered vault, so importing *adopts* them rather than
   recreating them. Key names and the vault ID are read from Terraform outputs, so nothing is hardcoded and it works for
   any `key_name_prefix`. Only keys missing from state are imported, so re-running is safe.
3. **Full `terraform apply`** — with vault and keys in state, this converges and plans no key changes.

This is also the path when the **state itself is gone** (fresh clone, or a remote-backend migration): the three steps
rebuild state around the existing vault and keys.

Notes:

- **The script never recreates the keys.** Spokes reference them by versioned URI; recreating would mint new versions
  and break every workspace's CMK until each spoke is updated. Recovery + import preserves the existing versions.
- **Run it against the same state** the vault belongs to — the versioned, locking remote backend, not a fresh local
  state (except in the deliberate "state is gone" rebuild case above). See the prerequisites at the top of this section.
- **If the vault is already recovered (live) but missing from the target state** — for example it was recovered into a
  different (local) state — `recover.sh` step 1 does not apply: it relies on soft-delete recovery, and against a *live*
  vault a targeted apply instead errors `already exists ... needs to be imported`. Adopt the existing resources with
  `terraform import` against the correct backend — the vault, the three keys, and the CMK role assignment (which the
  recovery recreated, since RBAC assignments have no soft-delete) — then a full apply converges.
- **A tags-only diff on the keys after recovery is the ARM tag-name-lowercasing behavior**, not drift — see the note in
  [`modules/keyvault/keys.tf`](modules/keyvault/keys.tf). The root module already lowercases tag names, so a re-plan is
  clean.

## Rebuilding remote state so the pipeline plans no changes

Use this when the **remote state for an environment is empty or lost** — a freshly bootstrapped backend, a wiped state
key, or after a `recover.sh` rebuild — and you want the CI pipeline's next `plan` to report **no changes**. The approach:
rebuild state locally around the existing Azure resources, then migrate that state up into the remote `azurerm` backend
the pipeline reads.

### Why local-first, then migrate

The backend uses `use_azuread_auth = true`, so reading and writing the state blob is governed by RBAC on the tfstate
storage account. The bootstrap layer grants the pipeline's **UAMI** `Storage Blob Data Contributor` on that account —
but **you, running locally as yourself, are not granted it**, so a local `terraform init` pointed straight at the backend
fails with:

```
Error: ... 403 ... AuthorizationPermissionMismatch: This request is not authorized to perform this operation ...
```

So we recover into **local** state first (which needs no blob access), then do a single authenticated `-migrate-state`
push to the backend.

### Prerequisite: grant yourself state-account access

```shell
# <tfstate-account> is the bootstrap output tfstate_storage_account_name for this subscription
# (e.g. sttfstatenonprod for dev/test, sttfstateprod for prd).
SA_ID=$(az storage account show -n <tfstate-account> -g rg-cicd-bootstrap --query id -o tsv)
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Storage Blob Data Contributor" \
  --scope "$SA_ID"
# allow a few minutes for RBAC to propagate
```

### Steps

```shell
cd tf/platform

# 1. Go local: disable the azurerm backend override, then reinitialize on local state.
mv backend_override.tf backend_override.tf.disabled
terraform init -reconfigure

#    If terraform still reports  Unsetting the previously set backend "azurerm"
#    (a stale backend pointer that -reconfigure did not clear), remove the pointer
#    and re-init. This discards only the backend association, not any real state:
rm -f .terraform/terraform.tfstate
terraform init
terraform state list          # expect "No state file was found!" — empty local state

# 2. Rebuild local state around the existing vault + keys.
./recover.sh -var-file=env/<env>.tfvars
#    Must converge to "No changes." A tags-only diff on the keys is the ARM
#    lowercasing quirk noted above — re-plan to confirm it settles before continuing.

# 3. Re-enable the backend and migrate local -> remote.
mv backend_override.tf.disabled backend_override.tf
terraform init -migrate-state -backend-config=env/<env>.backend.hcl   # answer "yes" to copy state up

# 4. Verify against the remote backend.
terraform plan -var-file=env/<env>.tfvars     # expect: No changes
```

Then run the platform pipeline with `action: plan` — it initializes the same state key and should report **no changes**.

### Notes

- **`-reconfigure` vs `-migrate-state`.** Going *to* local, use `-reconfigure` — don't `-migrate-state`, which would try
  to read the remote state you can't access and hit the 403. Pushing *back* to remote, use `-migrate-state` to copy the
  local state up.
- **Identity does not affect the plan.** `recover.sh` runs as you; the pipeline runs as the UAMI. State stores resource
  IDs, not who created them, so a clean local plan implies a clean pipeline plan — provided you use the **same
  `-var-file`**. The pipeline's extra `-var="use_oidc=true"` only changes provider auth, not resources.
- **Recover the right vault.** If several vaults are soft-deleted, `recover.sh` recovers whichever `env/<env>.tfvars`
  resolves to; confirm it is the one your spokes' CMK references before you converge.
- **Watch the state lock.** Don't run the pipeline against the same state key while you migrate, or you collide on the
  blob lease.
