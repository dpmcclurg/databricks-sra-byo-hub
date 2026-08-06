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

```shell
cd tf/platform
cp template_platform.example.tfvars my-platform.tfvars   # then fill it in
terraform init
terraform validate
terraform plan  -var-file my-platform.tfvars
terraform apply -var-file my-platform.tfvars

terraform output -raw spoke_tfvars_snippet                # paste into each spoke's var file
```

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

Afterwards the vault and keys are **soft-deleted, not gone**: purge protection cannot be turned off, so they stay
recoverable for `soft_delete_retention_days` (default 90 here) and the name stays reserved. Re-applying with the same
`key_vault_name` recovers them, because `recover_soft_deleted_key_vaults` is set. Reclaiming the name sooner needs
`az keyvault purge`, which is irreversible and destroys the key material.
