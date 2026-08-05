#!/usr/bin/env bash
#
# Checks that the backend private endpoint is ordered after everything that puts the workspace into the "Updating"
# state.
#
# Azure rejects a private endpoint against a workspace that is mid-update with:
#
#   InvalidWorkspaceProvisioningState: The workspace '<name>' is in 'Updating' state.
#
# Granting the workspace identities access to the vault does that, and so does setting the DBFS root CMK. None of them
# is a data dependency of the private endpoint, so only an explicit depends_on keeps them apart - and because it is a
# race, an apply can pass by luck when the ordering is missing.
#
# This is not a `terraform test` assertion because assertions can only read values, and depends_on is not a value. It
# is only visible in the plan's configuration JSON, which is what this reads.
#
# Usage: tests/check_private_endpoint_ordering.sh        (run from the tf/ directory)
set -euo pipefail

cd "$(dirname "$0")/.."

# Everything the backend private endpoint must come after
REQUIRED=(
  azurerm_key_vault_access_policy.dbstorage
  azurerm_key_vault_access_policy.dbmanageddisk
  azurerm_databricks_workspace_root_dbfs_customer_managed_key.this
)

plan=$(mktemp -t pe_ordering_plan)
json=$(mktemp -t pe_ordering_json)
trap 'rm -f "$plan" "$json"' EXIT

echo "Generating plan..."
terraform plan -input=false -out="$plan" >/dev/null
terraform show -json "$plan" >"$json"

# The workspace module's private endpoint, as recorded in the plan's configuration
deps=$(
  python3 -c '
import json, sys
with open(sys.argv[1]) as fh:
    plan = json.load(fh)

modules = plan.get("configuration", {}).get("root_module", {}).get("module_calls", {})
workspace = modules.get("spoke_workspace", {}).get("module", {})

for resource in workspace.get("resources", []):
    if resource.get("address") == "azurerm_private_endpoint.backend":
        print("\n".join(resource.get("depends_on", [])))
        break
else:
    sys.exit("could not find azurerm_private_endpoint.backend in the plan configuration")
' "$json"
)

status=0
for required in "${REQUIRED[@]}"; do
  if grep -qxF "$required" <<<"$deps"; then
    echo "  ok       backend private endpoint depends on $required"
  else
    echo "  MISSING  backend private endpoint must depend on $required"
    status=1
  fi
done

if [[ $status -ne 0 ]]; then
  echo
  echo "FAIL: the backend private endpoint can race the workspace into InvalidWorkspaceProvisioningState."
  echo "      Add the missing entries to depends_on in modules/workspace/backend_privatelink.tf."
  exit 1
fi

echo
echo "PASS: the backend private endpoint is ordered after all workspace-updating resources."
