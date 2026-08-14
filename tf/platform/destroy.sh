#!/usr/bin/env bash
#
# Tears down the platform layer: the shared Key Vault, its three CMKs, and the security resource group.
#
# READ THIS BEFORE RUNNING. This vault is shared. Every Azure Databricks workspace bound to it depends on these keys, and
# Azure Databricks documents lost keys as unrecoverable: if a key is revoked or deleted and cannot be restored, those
# workspaces' compute resources stop working. Destroying this while spokes exist is a fleet-wide outage, not a cleanup.
#
# This script guards three separate problems.
#
# 1. Live spokes
#
# Nothing in this state knows which workspaces reference the vault - that is the cost of separate states. So rather than
# trusting the operator to remember, this asks Azure directly, listing workspaces whose CMK configuration points at this
# vault's URI. Non-empty means stop.
#
# 2. prevent_destroy
#
# The vault and all three keys carry lifecycle { prevent_destroy = true }, so `terraform destroy` will refuse outright.
# That is intentional friction. Removing those blocks is a deliberate, reviewable edit - this script will not do it for
# you, and will not offer a -target or state-rm shortcut around it.
#
# 3. The ARM DELETE limitation
#
# ARM has no DELETE verb for Microsoft.KeyVault/vaults/keys:
#
#   RESPONSE 405: DeleteNotSupported
#   "The resource type does not support delete operation."
#
# Deleting a key is only ever a Key Vault *data plane* operation. That asymmetry is deliberate on the create side - it is
# what lets `terraform apply` create the keys through a firewalled vault with no IP allowlist, and what lets an RBAC vault
# be provisioned with no data-plane role at all - but it leaves destroy with no path, because azapi_resource has no option
# to skip the delete, and the keys depend on the vault transitively, so destroy always attempts them *first*.
#
# Deleting the vault removes its keys anyway, so the fix is to drop the keys from state and let the vault deletion do the
# work. Nothing is orphaned: the keys live inside the vault being deleted.
#
# Usage: ./destroy.sh [--force] [any additional terraform destroy arguments]
#        ./destroy.sh -var-file my-platform.tfvars
set -euo pipefail

cd "$(dirname "$0")"

force=false
args=()
for arg in "$@"; do
  if [[ $arg == "--force" ]]; then
    force=true
  else
    args+=("$arg")
  fi
done

# ------------------------------------------------------------------
# Guard 1: refuse while any workspace still points at this vault

vault_uri=$(terraform output -raw key_vault_uri 2>/dev/null || true)
vault_name=$(terraform output -raw key_vault_name 2>/dev/null || true)

if [[ -z $vault_uri ]]; then
  echo "Could not read key_vault_uri from state. If the platform layer is not applied, there is nothing to destroy."
  exit 1
fi

echo "Vault: $vault_name"
echo "  $vault_uri"
echo

if command -v az >/dev/null 2>&1; then
  echo "Checking for workspaces still using this vault..."

  # Both CMK locations have to be checked: managed services and managed disk sit under properties.encryption.entities,
  # while DBFS root sits under properties.parameters.encryption.value with different property casing.
  in_use=$(
    az databricks workspace list --only-show-errors --query \
      "[?properties.encryption.entities.managedServices.keyVaultProperties.keyVaultUri=='$vault_uri' \
        || properties.encryption.entities.managedDisk.keyVaultProperties.keyVaultUri=='$vault_uri' \
        || properties.parameters.encryption.value.keyvaulturi=='$vault_uri'].id" \
      -o tsv 2>/dev/null || true
  )

  if [[ -n $in_use ]]; then
    echo
    echo "REFUSING TO DESTROY: these workspaces still use this vault's keys."
    echo
    printf '  %s\n' $in_use
    echo
    echo "Destroying the vault would break their compute, and Azure Databricks documents lost keys as unrecoverable."
    echo "Destroy those spokes first (tf/destroy.sh), or re-run with --force if you are certain."
    $force || exit 1
    echo "--force given; continuing anyway."
    echo
  else
    echo "  none found."
    echo
  fi
else
  echo "WARNING: the az CLI is not available, so live spokes could not be checked for."
  echo "         Confirm by hand that no workspace uses this vault before continuing."
  echo
fi

# A shared vault deserves more than a y/N. Require the name to be typed out.
read -r -p "Type the vault name ($vault_name) to confirm destruction: " typed
if [[ $typed != "$vault_name" ]]; then
  echo "Names do not match. Aborted; nothing was changed."
  exit 1
fi
echo

# ------------------------------------------------------------------
# Guard 3: drop the keys from state, since ARM cannot delete them

# Read from state rather than hardcoded, so this copes with keys already removed by an earlier run.
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

# ------------------------------------------------------------------

echo "If terraform now refuses with \"Instance cannot be destroyed\", that is prevent_destroy doing its job."
echo "Remove the lifecycle blocks from modules/keyvault/main.tf and modules/keyvault/keys.tf deliberately, then re-run."
echo

terraform destroy "${args[@]+"${args[@]}"}"

cat <<EOF

────────────────────────────────────────────────────────────────────────────
The vault and its keys are soft-deleted, not gone.

Purge protection is enabled and cannot be turned off, so they stay recoverable
for the retention window (soft_delete_retention_days, default 90) and the vault
name stays reserved for that period.

That is usually what you want. To bring it back, run ./recover.sh (NOT a plain
re-apply): recovery restores the vault and its keys, but the keys were just
dropped from state, so a plain apply would try to recreate them and fail. The
script recovers the vault, imports the existing keys, then applies. See the
"Recovering from soft delete" section of README.md.

  ./recover.sh -var-file <your-var-file>

To reclaim the name sooner instead of recovering, purge it explicitly, which is
irreversible and destroys the key material for good:

  az keyvault purge --name $vault_name

────────────────────────────────────────────────────────────────────────────
EOF
