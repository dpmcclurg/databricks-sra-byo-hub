# Security Reference Architecture Template (BYO Hub)

This is a bring-your-own-hub variant of the Azure Databricks SRA. It deploys a **spoke workspace into an existing,
customer-managed hub** and never creates hub infrastructure. It also assumes the hub has **no Azure Firewall** and **no
BGP** from on-premises. See [Bring-your-own hub, no Azure Firewall](#bring-your-own-hub-no-azure-firewall).

# Getting Started

1. Clone this Repo
2. Install [Terraform](https://developer.hashicorp.com/terraform/downloads)
3. CD into `tf`
4. Copy `template_byo_hub.example.tfvars` to a var file of your own and supply your values, keeping it in the `tf`
   directory. Note that `.gitignore` excludes `*.tfvars` other than the example, so your own file will not be committed:

   ```shell
   cp template_byo_hub.example.tfvars my-spoke.tfvars
   ```

5. Run `terraform init`
6. Run `terraform validate`
7. Run `terraform plan -var-file my-spoke.tfvars`
8. Run `terraform apply -var-file my-spoke.tfvars`
9. **Have the hub owner create the reciprocal hub-to-spoke peering.** Run `terraform output hub_peering_command` and
   send them the result. The spoke peering stays disabled ("Remote sync required") and the spoke has no hub or
   on-premises connectivity until this is done — see [Completing the hub peering](#completing-the-hub-peering).

## Note on provider initialization with Azure CLI
If you are using [Azure CLI Authentication](https://registry.terraform.io/providers/databricks/databricks/latest/docs#authenticating-with-azure-cli),
you may encounter an error like the below:

```shell
Error: cannot create mws network connectivity config: io.jsonwebtoken.IncorrectClaimException: Expected iss claim to be: https://sts.windows.net/00000000-0000-0000-0000-000000000000/, but was: https://sts.windows.net/ffffffff-ffff-ffff-ffff-ffffffffffff/
```
This typically happens if you are running this Terraform in a tenant where you are a guest, or if you have multiple
Azure accounts configured. To resolve this error, set the Azure Tenant ID by exporting the `ARM_TENANT_ID` environment
variable:

```shell
export ARM_TENANT_ID="00000000-0000-0000-0000-000000000000"
```

Alternatively, you can set the tenant ID in the databricks provider configurations (see the provider [doc](https://registry.terraform.io/providers/databricks/databricks/latest/docs#special-configurations-for-azure) for more info.)

You may also encounter errors like the below when Terraform begins provisioning workspace resources:

```shell
╷
│ Error: cannot read current user: Unauthorized access to Org: 0000000000000000
│ 
│   with data.databricks_current_user.me,
│    1: data "databricks_current_user" "me" {}
│ 
╵
```

To fix this error, log in to the newly created spoke workspace by clicking on the "Launch Workspace" button in the Azure
portal. This must be done as the user who is running this Terraform, or the user running this Terraform must be granted
workspace admin after the first user launches the workspace.

# Introduction

Databricks has worked with thousands of customers to securely deploy the Databricks platform with appropriate security features to meet their architecture requirements.

This Security Reference Architecture (SRA) repository implements common security features as a unified terraform templates that are typically deployed by our security conscious customers.

# Component Breakdown and Description

In this section, we break down each of the components that we've included in this Security Reference Architecture.

In various .tf scripts, we have included direct links to the Databricks Terraform documentation. The [official documentation](https://registry.terraform.io/providers/databricks/databricks/latest/docs) can be found here.

## Infrastructure Deployment

- **Vnet Injection**: [Vnet injection](https://learn.microsoft.com/en-us/azure/databricks/security/network/classic/vnet-inject)
allows Databricks customers to exercise more control over your network configures to comply with specific cloud security and governance standards that a
customer's organization may require.

- **Private Endpoints**: Using Private Link technology, a [private endpoint](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview) is a service that connects a customer's Vnet
to Azure services without traversing public IP addresses.

- **Private Link Connectivity**: Private Link provides a private network route from one Azure service to another.
[Private Link](https://learn.microsoft.com/en-us/azure/private-link/private-link-overview) is configured
so that communication between the customer's data plane and Databricks control plane does not traverse public IP addresses. Back-end Private Link is set up in this template according
to the [Simplified Private Link](https://learn.microsoft.com/en-us/azure/databricks/security/network/classic/private-link-simplified) setup.

- **Unity Catalog**:  [Unity Catalog](https://learn.microsoft.com/en-us/azure/databricks/data-governance/unity-catalog) is a unified governance solution for all data and AI assets including
files, tables, and machine learning models. Unity Catalog provides a modern approach to granular access controls with centralized policy, auditing, and lineage tracking,
all integrated into your Databricks workflow.

## Bring-your-own hub, no Azure Firewall

This project **only** deploys a spoke workspace into an existing, customer-managed hub. It never creates a hub, a hub
("WEBAUTH") workspace, or an Azure Firewall. Hub resources — VNet, VPN gateway, metastore, NCC, and account network
policy — are supplied as `existing_*` inputs and must already exist.

The Key Vault is the exception: it is created **in the spoke** by default, one per deployment. See
[Customer-managed keys](#customer-managed-keys).

It further assumes the hub has **no Azure Firewall** and **no BGP** from the on-premises firewall. Egress filtering is
the responsibility of the existing on-premises perimeter.

The only hub input required for connectivity is the VNet ID:

```hcl
existing_hub_vnet = {
  vnet_id = "/subscriptions/.../virtualNetworks/vnet-external-hub"
}
```

With this configuration:

- **No route table, and no on-premises route list.** On-premises reachability comes from **gateway transit**, which
  propagates routes automatically — see [How on-premises routing works](#how-on-premises-routing-works) below.
- **The spoke uses the hub's gateway.** The spoke-to-hub peering sets `use_remote_gateways = true`, so the spoke
  inherits the hub's gateway. This depends on the hub-side peering setting `allow_gateway_transit` — see
  [Completing the hub peering](#completing-the-hub-peering).

### How on-premises routing works

When the hub peering sets `allow_gateway_transit` and the spoke sets `use_remote_gateways`, Azure **propagates the hub
gateway's learned routes into the spoke VNet as system routes**. That includes on-premises prefixes learned over
site-to-site or ExpressRoute, VNet-to-VNet prefixes, and the point-to-site VPN client address pool. Classic compute in
the injected VNet picks these up with no configuration.

No route table is created, because none is needed: gateway transit already supplies these routes. User-defined routes
are required only to **override** propagated routing — for example to force egress through a network virtual appliance
— which this topology does not do.

Two consequences worth understanding when troubleshooting:

- **A UDR to `VirtualNetworkGateway` does not make a network reachable.** It only directs matching traffic at the
  gateway. If the gateway has no path for that prefix (no site-to-site connection, no local network gateway advertising
  it), packets reach the gateway and are dropped. A route to an unreachable destination is a route to nowhere.
- **Point-to-site only routes the client's VPN-assigned address**, not the LAN behind it. When validating with a P2S
  client, target its address from the gateway's client pool (e.g. `192.168.200.x`), not its local network address
  (e.g. `192.168.2.x`). Reaching the LAN behind a client requires a site-to-site tunnel advertising that range.

To confirm what a spoke VM can actually route to, check its effective routes:

```shell
az network nic show-effective-route-table --name <NIC> --resource-group <RG> -o table
```

Note that Databricks applies a deny assignment to the managed resource group, so this cannot be run against cluster
NICs — use a VM you control in the same VNet, or inspect the propagated routes from the hub side.

### Completing the hub peering

**This deployment is not finished when `terraform apply` succeeds.** One manual step remains, and until it is done the
spoke has no connectivity to the hub or to on-premises.

Azure models VNet peering as **two independent resources, one in each VNet**. Both must exist before the link becomes
`Connected`. This configuration creates only the spoke half, because the hub is customer-managed and every hub resource
is an `existing_*` input that SRA does not modify.

The hub half **cannot be created in advance**: it must reference the spoke VNet's resource ID, which does not exist
until this configuration has run. It is therefore a post-apply handoff to the hub owner, not a prerequisite.

Until the hub side exists you will see, on the spoke peering:

- Peering state `Initiated` (not `Connected`)
- Sync status **"Remote sync required"**, shown as disabled in the portal
- No traffic between the spoke and the hub, and no on-premises reachability

After `terraform apply`, run `terraform output hub_peering_command` to print a ready-to-run command with your actual
resource names filled in, and send it to whoever administers the hub VNet. It looks like this:

```shell
az network vnet peering create \
  --name from-vnet-external-hub-to-vnet-spoke-peer \
  --resource-group rg-external-hub \
  --vnet-name vnet-external-hub \
  --subscription 00000000-0000-0000-0000-000000000000 \
  --remote-vnet /subscriptions/.../virtualNetworks/vnet-spoke \
  --allow-vnet-access \
  --allow-gateway-transit \
  --allow-forwarded-traffic
```

`terraform output hub_peering_required` gives the same values as structured data if the hub is managed by another
Terraform configuration or a ticketed process.

> **`--allow-gateway-transit` is required, not optional.** It is what permits the spoke's `use_remote_gateways = true`,
> and it is the *only* mechanism giving classic compute a route to on-premises — no UDRs are created. Without it the
> spoke receives no propagated gateway routes and cannot reach on-premises at all, even once the peering shows
> `Connected`.

Verify both sides report `Connected` when done:

```shell
az network vnet peering list --resource-group rg-external-hub --vnet-name vnet-external-hub \
  --query "[].{name:name,state:peeringState,sync:peeringSyncLevel}" -o table
```

If you later change the spoke VNet's address space, the hub peering must be re-synced
(`az network vnet peering sync`) — Azure does not propagate address space changes across an existing peering
automatically.

### Consequence: no internet egress for classic compute

Removing the firewall also removes the `0.0.0.0/0` route that carried outbound internet traffic. Classic compute
subnets fall back to the system default route, and because Azure has retired default outbound access for new
deployments, there may be **no internet egress path at all** — so public package installs (PyPI, CRAN) will fail.
Databricks control plane traffic is unaffected, as it uses back-end Private Link. If workloads need internet access,
provide an explicit path (NAT gateway, or a route to an egress appliance in the hub).

### Limitation: serverless compute cannot reach on-premises

Propagated gateway routes apply only to classic compute in the injected VNet. Serverless compute runs in a
Microsoft-managed VNet, so it does not receive them.

When validating on-premises connectivity from a notebook, **make sure the notebook is attached to a classic cluster.**
Results from a serverless notebook say nothing about this routing path.

Reaching on-premises from serverless requires an NCC private endpoint to an Azure Private Link Service fronting an
internal Standard Load Balancer. That path is **driven by DNS names, not IP ranges**: Databricks requires each
destination to be registered as a resolvable domain name, and
[DNS chasing, wildcard domains, and private-use TLDs such as `.internal` are not supported](https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/pl-to-internal-network).
Where on-premises systems are addressed by IP only, this is not currently possible, and it is **not configured by this
deployment**. Keep on-premises workloads on classic compute.

## Customer-managed keys

With `cmk_enabled = true` (the default), the workspace encrypts managed services and managed disks with
customer-managed keys. `cmk_source` decides where those keys come from:

| `cmk_source` | Behaviour |
| --- | --- |
| `"create"` (default) | Creates a Key Vault and two keys in the spoke resource group, with a private endpoint and `privatelink.vaultcore.azure.net` zone in the spoke |
| `"existing"` | Uses a vault and keys you already manage, supplied via `existing_cmk_ids` |

### Why the vault is in the spoke

A Key Vault must be in the **same region and Microsoft Entra ID tenant** as the workspace it serves. It may be in a
different subscription, but not a different region — which inverts the usual hub-and-spoke intuition, since crossing
subscriptions is fine and crossing regions is not. A single central vault therefore cannot serve spokes in more than one
region.

Two further reasons, both about ownership:

- **Blast radius, with no recovery path.** Lost keys are not recoverable: if a key is lost or revoked and cannot be
  restored, the workspace's compute resources stop working. A shared vault means one bad rotation, accidental purge, or
  over-broad access policy edit affects every environment at once. Per-deployment vaults also let production carry
  stricter access policies and retention settings than a sandbox.
- **The workspace writes to the vault.** Access policies are granted to the workspace's storage and managed disk
  identities, which only exist *after* the workspace is created. With a shared vault, every deployment needs write
  permission on it, and N deployments mutate one vault's access policies from N separate Terraform states.

Purge protection is enabled and cannot be disabled afterwards.

### Vault network access

The vault gets a private endpoint and a `privatelink.vaultcore.azure.net` zone in the spoke. Public network access is
disabled and the firewall denies by default, with exactly one exception:

- **`bypass = "AzureServices"`** is what actually permits CMK. Neither CMK unwrap call reaches the vault through the
  private endpoint: managed services keys are unwrapped by the Databricks **control plane**, and managed disk keys by the
  **Disk Encryption Set** in the workspace's managed resource group. Both sit outside the spoke VNet. Azure Databricks
  and Azure Disk Storage are both Key Vault trusted services, so the bypass admits them. Remove it and clusters fail to
  start with `KeyVaultAccessForbidden`.

  This is not something an NCC private endpoint rule can replace. Key Vault *is* a supported NCC resource type, so
  serverless compute can reach a vault privately — a Key Vault-backed secret scope, for instance — but NCC private
  endpoints serve **serverless compute egress** (SQL warehouses, jobs, notebooks, Lakeflow pipelines, model serving), and
  neither CMK caller is serverless compute. An NCC private endpoint also lives in the Databricks-managed serverless
  network, not in this spoke, so it is a different endpoint from the one this module creates.
The Disk Encryption Set is why the bypass cannot be traded for an IP allowlist: it has **no published IP range**. The
control plane does publish Control Plane NAT ranges per region, so managed services could in principle be allowlisted —
but that would leave managed disk CMK broken, so the bypass is required regardless and an allowlist would add nothing.
Splitting into two vaults, one per key, to narrow the bypass to disks only was considered and rejected: it doubles the
operational surface and still leaves a bypass vault.

There is **no IP allowlist and no exception for the provisioner**, because the keys are not created over the data plane.
The module creates them as ARM resources (`Microsoft.KeyVault/vaults/keys` via `azapi_resource`) rather than with
`azurerm_key_vault_key`. That matters because, per the Key Vault networking docs, "Key Vault firewall rules only apply to
data plane operations. Control plane operations are not subject to the restrictions specified in firewall rules." So
`terraform apply` provisions the keys through `management.azure.com` and succeeds from anywhere, while
`<vault>.vault.azure.net` stays closed to the internet.

Using `azurerm_key_vault_key` instead would reintroduce a data-plane call and fail with `403` unless the vault's public
endpoint were opened to the machine running Terraform.

Do **not** set the vault's public network access to **Secured by Perimeter** (associating it with a Network Security
Perimeter in enforced mode). Enforced mode overrides the trusted-services bypass, which breaks CMK for both key types.
Azure's portal recommends Secured by Perimeter for resources in a perimeter, so this is an easy trap. Databricks guidance
is to stay in NSP transition mode, where resource firewall rules still apply — but transition mode does not replace the
firewall rules above, so a perimeter adds nothing for this vault. NSP's supported Databricks use case is allowing
serverless compute to reach **storage accounts** via the `AzureDatabricksServerless` service tag; that tag does not apply
to Key Vault.

### Key versions and rotation

Databricks requires a **specific key version**, not `latest`. The workspace API takes vault URI + key name + key
version, so versionless key IDs are not expressible: the module emits versioned IDs and `existing_cmk_ids` rejects
versionless ones.

The two keys rotate differently:

- **Managed disk** — `managed_disk_cmk_rotation_to_latest_version_enabled` is on, so the Disk Encryption Set picks up new
  key versions by itself. The versioned ID in state records the version at apply time; the DES is free to move past it.
- **Managed services** — no auto-rotation flag exists. Rotating means creating a new key version and running `terraform
  apply`. Keep the old version available for **24 hours** after the update, and do not delete it until the workspace
  update completes.

#### Verifying disk key auto-rotation

Whether a workspace read returns the originally configured key version or the rotated-to version is not documented, so
this is worth checking once per deployment. It matters because if Azure reports the rotated version, Terraform sees drift
and tries to revert it.

1. Record the version currently in use:

   ```bash
   az databricks workspace show \
     --resource-group <rg> --name <workspace> \
     --query "properties.encryption.entities.managedDisk" -o json
   ```

   Note `keyVaultProperties.keyVersion` and confirm `rotationToLatestKeyVersionEnabled` is `true`.

2. Create a new version of the disk key. Rotation is a Key Vault data-plane operation, so run this from a host that
   reaches the vault over its private endpoint, or rotate through the portal:

   ```bash
   az keyvault key rotate --vault-name <vault> --name <key-name>-adb-disk
   ```

3. Re-run the command from step 1. Within a few minutes `keyVersion` should advance to the new version — that confirms
   the DES is following rotations.

4. Run `terraform plan`. **No changes** is the desired outcome. If the plan wants to set `keyVersion` back to the old
   value, add `ignore_changes = [managed_disk_cmk_key_vault_key_id]` to the workspace resource rather than disabling
   auto-rotation.

5. Confirm compute still works by starting a cluster. A failure here points at Key Vault permissions for the Disk
   Encryption Set rather than at rotation.

Do not delete the old key version until after step 5 passes.

### Which CMK features are enabled, and why

Three keys are created, one per CMK scope. They are not equally important, and the priority reflects what each protects:

| Priority | Scope | Protects | What it is |
| --- | --- | --- | --- |
| **Must** | Managed services | Notebook source, secrets, SQL queries and query history, PATs, dashboards | Data at rest in the Databricks **control plane** — outside your subscription |
| **Should** | DBFS root | Job results, SQL results, large notebook results, notebook revisions, MLflow artifacts, FileStore | The workspace storage account, in your subscription |
| **Optional** | Managed disks | Disk cache on classic compute VMs | Ephemeral scratch, in your subscription |

**Managed services** ranks first because the data lives in the control plane rather than in your subscription, so a
customer-managed key is the only control that gives you a revocation lever over it.

**DBFS root** is worth enabling even when all production data is in Unity Catalog. Databricks deprecates *storing
production data in DBFS root* — it does not deprecate this feature, and the workspace storage account keeps receiving
job results, Databricks SQL results, large interactive notebook results, notebook revisions, MLflow artifacts written to
the workspace-default location, FileStore, and any init scripts kept in DBFS. None of that is production data, but it can
contain sensitive values derived from it: query output over a PII table, a model trained on regulated data. No setting
prevents the platform writing there, so the residual cannot be designed away — and enabling the key is cheap.

**Managed disks** is genuinely optional rather than a gap, because the data is already protected several ways over:

- Ephemeral — destroyed when the cluster terminates
- Encrypted by default with a platform-managed key
- Network-inaccessible — data disks have **Disable public and private access** applied, and the default cannot be changed
- Protected by [deny assignments](https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments) on
  the managed resource group, so the disks cannot be exported even by a subscription administrator; the network setting
  only applies to import/export, which is already denied
- Not applicable to serverless, where disks are tied to the workload lifecycle

It is enabled here as defence in depth, not to close an open hole. Note that once enabled it **cannot be disabled**.

For the reasoning behind the public-access settings on the workspace storage account and cluster disks, see the internal
whitepaper *Azure Databricks — Public Access Settings for DBFS Root & Managed Disks*.

## Workspace default storage

Every Azure Databricks workspace has a default storage account in its managed resource group. It holds workspace system
data, MLflow artifacts, query results, and the DBFS root. The account is **mandatory and cannot be removed**, so
securing it is a separate concern from whether DBFS itself is used.

Access to it is secured by `secure_workspace_default_storage`, which sets `default_storage_firewall_enabled` on the
workspace and provisions private endpoints plus a dedicated access connector for it.

Note that this template does not manage the DBFS root and mounts setting. Accounts created after December 19, 2025 have
no access to legacy features by default, so DBFS is already disabled without any configuration. For older accounts,
disable it per workspace from **Settings → Workspace admin → Security**, or at the account level so that new workspaces
are provisioned without legacy features. Bear in mind that disabling DBFS requires Databricks Runtime 13.3 LTS or later
on all compute.

Enabling the storage firewall is recommended even where it is not strictly required. Its prerequisites — VNet
injection, secure cluster connectivity, Premium SKU, an access connector, and private endpoints — are already met by
this template, and turning it on later is the disruptive path: that is when a connector in the managed resource group
gets deleted and Unity Catalog external locations bound to it must be remapped. Enabling it from the first apply avoids

Enabling the storage firewall is recommended even where it is not strictly required. Its prerequisites — VNet
injection, secure cluster connectivity, Premium SKU, an access connector, and private endpoints — are already met by
this template, and turning it on later is the disruptive path: that is when a connector in the managed resource group
gets deleted and Unity Catalog external locations bound to it must be remapped. Enabling it from the first apply avoids
that entirely.

### Why there are two access connectors

- `id-databricks-uc-<suffix>` — used by Unity Catalog to reach the catalog's storage account.
- `id-databricks-ws-<suffix>` — used by the control plane and serverless plane to reach the **workspace default
  storage** account. Required when the storage firewall is enabled.

Each identity is granted roles scoped only to its own storage account, so a Unity Catalog credential cannot reach
workspace storage and vice versa.

Note that this template creates the workspace connector in the **spoke resource group, not the managed resource
group**. Enabling the storage firewall can delete an access connector that resides in the managed resource group,
which would force you to remap any Unity Catalog external locations bound to it. Keep it outside the managed group.

## Post Workspace Deployment

- **Admin Console Configurations**: There are a number of configurations within the [admin console](https://docs.databricks.com/administration-guide/admin-console.html) that
can be controlled to reduce your threat vector. The AWS directory contains examples of configuring these, should your organization desire them.

- **Cluster Tags and Pool Tags**: [Cluster and pool tags](https://learn.microsoft.com/en-us/azure/databricks/administration-guide/account-settings/usage-detail-tags) allow customers to
monitor cost and accurately attribute Databricks usage to your organization's business unit and teams (for chargebacks, for examples). These tags propagate to detailed
DBU usage reports for cost analysis.

## Adding additional spokes

This configuration deploys a single spoke per Terraform state. There is no `modules/spoke` and no `spoke_config`
variable.

To deploy additional spokes into the same existing hub, use one of the following:

1. **Separate state per spoke (recommended).** Run this configuration once per spoke with its own var file, backend key,
   and `resource_suffix`. Each spoke peers to the same `existing_hub_vnet` and binds to the same `existing_ncc_id` and
   `existing_network_policy_id`. Give each spoke a non-overlapping `workspace_vnet.cidr`.

2. **Terraform workspaces.** One `terraform workspace` per spoke against the same configuration, again varying
   `resource_suffix` and `workspace_vnet.cidr`.

Each spoke gets its on-premises routes from gateway transit via its own peering, so there is nothing per-spoke to
configure for routing beyond the peering itself (including the hub-side half — see
[Completing the hub peering](#completing-the-hub-peering)).

# Additional Security Recommendations and Opportunities

In this section, we break down additional security recommendations and opportunities to maintain a strong security posture that either cannot be configured into this
Terraform script or is very specific to individual customers (e.g. SCIM, SSO, etc.)

- **Segment Workspaces for Various Levels of Data Separation**: While Databricks has numerous capabilities for isolating different workloads, such as table ACLs and
IAM passthrough for very sensitive workloads, the primary isolation method is to move sensitive workloads to a different workspace. This sometimes happens when
a customer has very different teams (for example, a security team and a marketing team) who must both analyze different data in Databricks.

- **Avoid Storing Production Datasets in Databricks File Store**: Because the DBFS root is accessible to all users in a workspace, all users can access any data stored here.
It is important to instruct users to avoid using this location for storing sensitive data. The default location for managed tables in the Hive metastore on Databricks is the DBFS root;
to prevent end users who create managed tables from writing to the DBFS root, declare a location on external storage when creating databases in the Hive metastore.

- **Single Sign-On, Multi-factor Authentication, SCIM Provisioning**: Most production or enterprise deployments enable their workspaces to use
[Single Sign-On (SSO)](https://learn.microsoft.com/en-us/azure/databricks/security/auth-authz/#sso) and multi-factor authentication (MFA).
As users are added, changed, and deleted, we recommended customers integrate [SCIM (System for Cross-domain Identity Management)](https://learn.microsoft.com/en-us/azure/databricks/administration-guide/users-groups/scim)
to their account console to sync these actions.

- **Backup Assets from the Databricks Control Plane**: While Databricks does not offer disaster recovery services, many customers use Databricks capabilities, including the Account API,
to create a cold (standby) workspace in another region. This can be done using various tools such as the Databricks [migration tool](https://github.com/databrickslabs/migrate),
[Databricks sync](https://github.com/databrickslabs/databricks-sync), or the [Terraform exporter](https://registry.terraform.io/providers/databricks/databricks/latest/docs/guides/experimental-exporter)

- **Regularly Restart Databricks Clusters**: When you restart a cluster, it gets the latest images for the compute resource containers and the VM hosts. It is particularly important
to schedule regular restarts for long-running clusters such as those used for processing streaming data. If you enable the compliance security profile for your account or your workspace,
long-running clusters are automatically restarted after 25 days. Databricks recommends that admins restart clusters manually during a scheduled maintenance window.
This reduces the risk of an auto-restart disrupting a scheduled job.

- **Evaluate Whether your Workflow requires using Git Repos or CI/CD**: Mature organizations often build production workloads by using CI/CD to integrate code scanning,
better control permissions, perform linting, and more. When there is highly sensitive data analyzed, a CI/CD process can also allow scanning for known scenarios such as hard coded secrets.

# Network Diagram

![Architecture Diagram](https://cms.databricks.com/sites/default/files/inline-images/db-9734-blog-img-4.png)
