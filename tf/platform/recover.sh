#!/usr/bin/env bash
#
# Recovers the platform layer after the shared Key Vault has been soft-deleted (by destroy.sh, or an accidental delete)
# and brings its keys back under Terraform management.
#
# READ THIS FIRST. There is an order-of-operations trap here that a plain `terraform apply` walks straight into, which is
# the whole reason this script exists.
#
# What recovery actually does
#
# When a soft-deleted vault is recovered, Azure restores the vault AND every key inside it, with their versions intact -
# keys are not recovered separately, and their names stay globally reserved while soft-deleted so they cannot be
# recreated. (See https://learn.microsoft.com/en-us/azure/key-vault/general/key-vault-recovery.) This layer sets
# recover_soft_deleted_key_vaults, so applying the vault resource recovers it rather than failing on the reserved name.
#
# The trap
#
# The keys are created with azapi_resource (an ARM control-plane write). After a destroy, those key resources were
# dropped from state (ARM cannot delete keys, so destroy.sh removes them from state and lets the vault deletion take
# them). So on recovery:
#
#   - A plain `terraform apply` recovers the vault, and then - in the SAME apply - tries to CREATE the three keys, which
#     already exist inside the just-recovered vault. ARM returns a conflict and the apply fails. This is the error you
#     hit if you "just re-apply".
#   - Running `terraform import` first does not work either: if the vault is still soft-deleted, the keys are not live,
#     so there is nothing to import.
#
# The correct order, which this script performs
#
#   1. Recover the vault ONLY (terraform apply -target the vault resource). This restores the vault and its keys without
#      attempting to create anything.
#   2. Import the now-live keys into state. They already exist in the recovered vault; importing adopts them instead of
#      recreating them, so no new key versions are minted and no spoke's CMK reference breaks.
#   3. Full terraform apply. With the vault and keys in state, this converges: it reconciles the role assignment, private
#      endpoint, and anything else, and plans no key changes.
#
# This is also the path to use when the state itself is gone (fresh clone, or a remote-backend migration): steps 1-3
# rebuild state around the existing vault and keys.
#
# Usage: ./recover.sh -var-file my-platform.tfvars [additional terraform arguments]
set -euo pipefail

cd "$(dirname "$0")"

# Terraform args (var-file etc.) are passed straight through to every terraform invocation below.
args=("$@")

vault_addr="module.vault.azurerm_key_vault.this"
cmk_role_addr="module.vault.azurerm_role_assignment.databricks_cmk"

# Resource addresses of the three CMK keys, paired with the output/attribute needed to build each import ID.
key_addrs=(
  "module.vault.azapi_resource.managed_services_key"
  "module.vault.azapi_resource.dbfs_root_key"
  "module.vault.azapi_resource.managed_disk_key"
)

# API version pinned on the key resources in keys.tf (Microsoft.KeyVault/vaults/keys@<version>). The key import IDs must
# carry it: without it azapi imports at its own latest default api-version, and the next apply then shows a benign but
# noisy in-place update on all three keys (~ type "...@<newer>" -> "...@<this>"). Keep in sync with keys.tf.
key_api_version="2023-07-01"

# ---------------------------------------------------------------------------------------------------------------------
# Guard: recovery must run against the SAME state the vault belongs to.
#
# recover.sh operates on whatever backend this directory is initialised to. Recovering into a LOCAL terraform.tfstate
# (the backend "azurerm" block left commented) adopts the vault into a state that diverges from the pipeline's remote
# state - the next pipeline run then fails with "already exists ... needs to be imported". Local state is only correct
# for the throwaway local-testing path (create_security_resource_group = true). Warn rather than hard-refuse so that path
# still works; set RECOVER_ALLOW_LOCAL_STATE=1 to skip the prompt (e.g. deliberate local recovery).
# ---------------------------------------------------------------------------------------------------------------------
if [[ -f .terraform/terraform.tfstate ]] && grep -q '"type": *"azurerm"' .terraform/terraform.tfstate; then
  : # initialised to a remote azurerm backend - the expected case
elif [[ ${RECOVER_ALLOW_LOCAL_STATE:-0} != 1 ]]; then
  echo "WARNING: this directory is not initialised to a remote (azurerm) backend, so recovery would write to LOCAL state."
  echo "  That is correct ONLY for throwaway local testing. For a vault whose state lives in the remote backend,"
  echo "  uncomment the backend block in versions.tf and re-init FIRST:"
  echo "      terraform init -backend-config=env/<env>.backend.hcl"
  echo "  Otherwise the next pipeline run fails with 'already exists ... needs to be imported'."
  echo
  read -r -p "Continue with local state anyway? [y/N] " ans </dev/tty || ans=N
  [[ ${ans:-N} =~ ^[Yy]$ ]] || { echo "Aborting. Re-init against the remote backend and re-run (or set RECOVER_ALLOW_LOCAL_STATE=1)."; exit 1; }
fi

# ---------------------------------------------------------------------------------------------------------------------
# Step 1: recover the vault only.
#
# Targeting just the vault resource is what avoids the trap: it triggers recover_soft_deleted_key_vaults without letting
# the same apply attempt to create the keys (which already exist in the recovered vault).
# ---------------------------------------------------------------------------------------------------------------------

echo "Step 1/4: recovering the Key Vault (vault resource only)..."
echo

# Show the soft-deleted vault if az is available, so the operator can confirm this is the right one before recovering.
if command -v az >/dev/null 2>&1; then
  echo "Soft-deleted vaults visible to this identity:"
  az keyvault list-deleted --resource-type vault \
    --query "[].{name:name, deleted:properties.deletionDate, scheduledPurge:properties.scheduledPurgeDate}" \
    -o table 2>/dev/null || echo "  (could not list; continuing)"
  echo
fi

terraform apply -target="$vault_addr" "${args[@]+"${args[@]}"}"
echo

# ---------------------------------------------------------------------------------------------------------------------
# Step 2: restore the CMK role assignment for the Azure Databricks control plane.
#
# Recovering the vault restores the vault and its keys, but NOT the role assignments on it - RBAC assignments are
# separate Microsoft.Authorization resources with no soft-delete, so a destroy removes them permanently. Without this
# grant the vault is RBAC-authorized with no assignments, so every data-plane caller gets 403 - including the Databricks
# control plane when a spoke workspace tries to wrap the managed-services key (ErrorInitializingWorkspace / ForbiddenByRbac).
#
# This grant lives in rbac.tf and references only the vault and the Databricks SP - it has no dependency on the keys - so
# it can be applied on its own here without dragging the not-yet-imported keys into a create. Doing it before the import
# also gives the assignment a head start on RBAC propagation, which is eventually consistent and can take minutes.
# ---------------------------------------------------------------------------------------------------------------------

echo "Step 2/4: restoring the Databricks CMK role assignment on the vault..."
echo

terraform apply -target="$cmk_role_addr" "${args[@]+"${args[@]}"}"
echo
echo "Note: Azure RBAC is eventually consistent - allow a few minutes for this grant to propagate before any spoke"
echo "workspace tries to use the vault, or the workspace create will 403 (ForbiddenByRbac) until it lands."
echo

# ---------------------------------------------------------------------------------------------------------------------
# Step 3: import the keys that exist in the recovered vault but are not in state.
#
# The import ID is the key's ARM resource ID:
#   <vault_id>/keys/<key_name>
# The vault ID and key names are read from Terraform outputs. Both outputs derive from inputs and the naming module, not
# from the key resources, so they resolve even though the keys are not yet in state - which is the whole point here.
# ---------------------------------------------------------------------------------------------------------------------

echo "Step 3/4: importing existing keys into state..."
echo

vault_id=$(terraform output -raw key_vault_id 2>/dev/null || true)
if [[ -z $vault_id ]]; then
  echo "ERROR: could not read key_vault_id from state after the recovery apply. Cannot build key import IDs."
  echo "       Re-run step 1, or check that the -var-file argument was passed."
  exit 1
fi

# key_names is built from the key_name_prefix (inputs + naming module), not from the key resources, so it resolves even
# though the keys are absent from state. Read it as JSON to stay robust to ordering; error rather than guess names.
if ! key_names_json=$(terraform output -json key_names 2>/dev/null); then
  echo "ERROR: could not read key_names output. Cannot determine key names to import."
  exit 1
fi

# Map each resource address to its key name. The outputs.tf order is [managed_services, dbfs_root, managed_disk], which
# matches key_addrs above.
#
# printf uses '%s\n', not '%s': $(...) strips the trailing newline off `terraform output`, so without adding one back
# the last key lands on an unterminated line, `while read` returns non-zero on it and skips its body, and the final key
# is silently dropped (the "expected 3 key names but read 2" failure).
key_names=()
# `|| [[ -n $name ]]` processes the final element too: the compact JSON has no trailing newline after the last name, so a
# plain `while read` exits at EOF before adding it (dropping the last key, e.g. the managed-disk key).
while IFS= read -r name || [[ -n $name ]]; do
  [[ -n $name ]] && key_names+=("$name")
done < <(printf '%s\n' "$key_names_json" | tr -d '[]" ' | tr ',' '\n')

if [[ ${#key_names[@]} -ne ${#key_addrs[@]} ]]; then
  echo "ERROR: expected ${#key_addrs[@]} key names but read ${#key_names[@]} from the key_names output."
  printf '  %s\n' "${key_names[@]}"
  exit 1
fi

# Back up state before any import, since state edits are easy to get wrong and hard to undo. `terraform state push`
# restores it.
backup="terraform.tfstate.backup.$(date +%Y%m%d%H%M%S)"
terraform state pull >"$backup"
echo "State backed up to $backup"
echo

# Which keys are already in state? Import only the missing ones, so re-running the script is safe.
in_state=$(terraform state list 2>/dev/null || true)

for i in "${!key_addrs[@]}"; do
  addr="${key_addrs[$i]}"
  name="${key_names[$i]}"
  import_id="${vault_id}/keys/${name}?api-version=${key_api_version}"

  if grep -qxF "$addr" <<<"$in_state"; then
    echo "  already in state, skipping: $addr"
    continue
  fi

  echo "  importing $addr"
  echo "    id: $import_id"
  terraform import "${args[@]+"${args[@]}"}" "$addr" "$import_id"
done
echo

# ---------------------------------------------------------------------------------------------------------------------
# Step 4: full apply to converge.
# ---------------------------------------------------------------------------------------------------------------------

echo "Step 4/4: full apply to converge (expect no changes to the three keys or the role assignment)..."
echo

terraform apply "${args[@]+"${args[@]}"}"

cat <<'EOF'

────────────────────────────────────────────────────────────────────────────
Recovery complete.

The vault and its three keys are back under Terraform management with their
original versions preserved, so every spoke's CMK reference still resolves and
no key versions were minted.

If the final apply reported a tags-only diff on the keys and would not settle,
that is the ARM tag-name-lowercasing behavior, not drift - the root module
already lowercases tag names, so a re-plan should be clean. See the note in
modules/keyvault/keys.tf.
────────────────────────────────────────────────────────────────────────────
EOF
