#!/usr/bin/env bash
#
# Tears down the spoke deployment, working around an ARM limitation that makes a plain `terraform destroy` fail, and
# prints the hub-side peering cleanup the hub owner has to run afterwards.
#
# 1. The CMK keys cannot be deleted by Terraform
#
# The keys are ARM resources (Microsoft.KeyVault/vaults/keys via azapi_resource), and ARM has no DELETE verb for that
# resource type:
#
#   RESPONSE 405: DeleteNotSupported
#   "The resource type does not support delete operation."
#
# Deleting a key is only ever a Key Vault *data plane* operation. That asymmetry is deliberate on the create side - it
# is what lets `terraform apply` create the keys through a firewalled vault with no IP allowlist (see the comment above
# the key resources in modules/keyvault/main.tf) - but it leaves destroy with no path, because:
#
#   - azapi_resource has no option to skip or no-op the delete call, and
#   - the keys depend on the vault transitively (parent_id), so destroy always attempts them *before* the vault, and
#   - the data-plane delete needs network access most operators running this do not have.
#
# Deleting the vault removes its keys anyway, so the fix is to drop the keys from state and let the vault deletion do
# the work. Nothing is orphaned: the keys live inside the vault being deleted.
#
# 2. The hub half of the peering is not ours to delete
#
# Azure models VNet peering as two independent resources, one per VNet. This configuration only manages the spoke half,
# because the hub is customer-managed (see the existing_* inputs). Destroying the spoke therefore leaves the hub half
# behind, pointing at a VNet that no longer exists - it goes to "Disconnected" and has to be deleted by the hub owner.
#
# This is the mirror image of the `hub_peering_command` output used after apply. It cannot be a Terraform output,
# because outputs are read from state and by the time the destroy finishes the state is empty. So the values are
# captured *before* the destroy and printed afterwards.
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

# Key resources as they appear in state. Read from state rather than hardcoded, so this copes with CMK being disabled
# (no keys), with or without the module count index, and with keys already removed by an earlier run.
#
# Uses a while-read loop rather than `mapfile`, which macOS's bash 3.2 does not have.
keys=()
while IFS= read -r line; do
  [[ -n $line ]] && keys+=("$line")
done < <(terraform state list | grep -E 'azapi_resource\.(managed_services_key|dbfs_root_key|managed_disk_key)$' || true)

if [[ ${#keys[@]} -eq 0 ]]; then
  echo "No CMK key resources in state - nothing to remove before destroy."
else
  echo "The following resources must be removed from state before destroy, because ARM cannot delete them:"
  printf '  %s\n' "${keys[@]}"
  echo
  echo "They are deleted along with the Key Vault itself, so this does not orphan anything."
  echo

  # The state edit happens before terraform's own destroy confirmation, so confirm here too - otherwise declining at
  # that later prompt would leave the keys already dropped from state.
  read -r -p "Remove them from state and continue to destroy? [y/N] " reply
  if [[ ! $reply =~ ^[Yy]$ ]]; then
    echo "Aborted. State is unchanged."
    exit 1
  fi

  # State surgery is easy to get wrong and hard to undo, so keep a copy. `terraform state push` restores it.
  backup="terraform.tfstate.backup.$(date +%Y%m%d%H%M%S)"
  terraform state pull >"$backup"
  echo "State backed up to $backup"

  terraform state rm "${keys[@]}"
  echo
fi

# Purge protection is enabled on the vault and cannot be turned off, so the vault and its keys stay soft-deleted for the
# retention window and the name stays reserved. That is expected. The vault name carries a random suffix, so a later
# deployment will not collide with the soft-deleted one.
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
