#!/usr/bin/env bash
#
# Runs `terraform destroy` and then prints the hub-side peering cleanup that Terraform cannot perform.
#
# This wrapper is a convenience, not a safeguard: it passes its arguments through unchanged and adds no preconditions, so
# plain `terraform destroy` tears the spoke down just as safely. Its only value is the message at the end, which is empty
# when this configuration never created a peering (create_hub_peering = false, or a network-team-owned VNet).
#
# Azure models VNet peering as two independent resources, one per VNet, and this configuration manages only the spoke half
# because the hub is customer-managed. Destroying the spoke therefore leaves the hub half pointing at a VNet that no longer
# exists, where it shows as "Disconnected" and has to be deleted by the hub owner.
#
# That cannot be a Terraform output - outputs are read from state, and the state is empty once the destroy finishes - so the
# values are captured before the destroy and printed after.
#
# The shared Key Vault and its CMKs are not touched; they belong to tf/platform and outlive every spoke bound to them.
# To tear down the vault itself, see tf/platform/destroy.sh, which does carry a real guard.
#
# Usage: ./destroy.sh [any additional terraform destroy arguments]
#        ./destroy.sh -var-file my-spoke.tfvars
set -euo pipefail

cd "$(dirname "$0")"

# Capture the hub peering details before the destroy, while state still exists. Failure here is not fatal - it just
# means no cleanup command is printed at the end, which must never block the teardown.
hub_peering=""
if hub_peering_json=$(terraform output -json hub_peering_required 2>/dev/null); then
  hub_peering=$hub_peering_json
fi

# The shared vault and its keys survive this, by design. Nothing here references them except through variables, so a spoke
# teardown cannot revoke keys another workspace is using.
#
# The DBFS root CMK is not unset before the workspace is deleted either: azapi_update_resource performs no operation on
# delete, so the workspace is deleted with the key still configured. Deleting needs no vault access, so nothing races.
terraform destroy "$@"

# Only reached when the destroy succeeds, since `set -e` exits on failure. That is deliberate: on a partial destroy the
# spoke VNet may still exist, and telling the hub owner to delete a live peering would be wrong.
if [[ -n $hub_peering ]]; then
  python3 - "$hub_peering" <<'PY'
import json
import sys

peering = json.loads(sys.argv[1])

subscription = peering["hub_subscription_id"]
resource_group = peering["hub_resource_group"]
vnet = peering["hub_vnet_name"]
name = peering["suggested_name"]

print(f"""
────────────────────────────────────────────────────────────────────────────
One manual step remains: the hub half of the peering still exists.

Azure peering is two resources, one per VNet, and this configuration only
manages the spoke half. The hub half now points at a deleted VNet and will
show as "Disconnected". Send this to whoever administers the hub VNet:

  # Run as a principal with Network Contributor on the hub VNet:
  az network vnet peering delete \\
    --name {name} \\
    --resource-group {resource_group} \\
    --vnet-name {vnet} \\
    --subscription {subscription}

  # Then confirm it is gone:
  az network vnet peering list \\
    --resource-group {resource_group} \\
    --vnet-name {vnet} \\
    --subscription {subscription} \\
    --query "[].{{name:name,state:peeringState}}" -o table

Leaving it in place is not harmful, but it blocks re-peering a new spoke that
reuses the same VNet name, and a stale peering has to be deleted rather than
re-synced.
────────────────────────────────────────────────────────────────────────────""")
PY
fi
