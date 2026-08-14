output "key_vault_id" {
  description = "Resource ID of the Key Vault"
  value       = azurerm_key_vault.this.id
}

output "key_vault_name" {
  description = "Name of the Key Vault"
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "URI of the Key Vault. Consumed by the spoke for the DBFS root CMK ARM body."
  value       = azurerm_key_vault.this.vault_uri
}

# ------------------------------------------------------------------
# Security posture, exposed so it can be asserted in tests rather than only reviewed by eye

output "purge_protection_enabled" {
  description = "Whether purge protection is enabled on the vault"
  value       = azurerm_key_vault.this.purge_protection_enabled
}

output "public_network_access_enabled" {
  description = "Whether the vault allows public network access. False by design - in-VNet clients reach it over a per-spoke private endpoint, and the keys are created through ARM, which the vault firewall does not govern."
  value       = azurerm_key_vault.this.public_network_access_enabled
}

output "rbac_authorization_enabled" {
  description = "Whether the vault uses Azure RBAC rather than access policies for data actions"
  value       = azurerm_key_vault.this.rbac_authorization_enabled
}

output "network_acls_default_action" {
  description = "Default action of the vault firewall. Deny means only the bypass and IP rules reach the vault."
  value       = one(azurerm_key_vault.this.network_acls).default_action
}

output "network_acls_bypass" {
  description = "Vault firewall bypass. AzureServices is required for CMK - the Databricks control plane and the Disk Encryption Set both reach the vault this way."
  value       = one(azurerm_key_vault.this.network_acls).bypass
}

# The scope is asserted in tests because vault-scoped is a deliberate choice, not an accident: key-scoped assignments
# provide no isolation (per the Key Vault RBAC FAQ) while breaking vault-level administration. See rbac.tf.
output "cmk_role_assignment_scope" {
  description = "Scope of the CMK role assignment. Should equal key_vault_id - the vault, not an individual key."
  value       = azurerm_role_assignment.databricks_cmk.scope
}

output "cmk_role_definition_name" {
  description = "Role granted for CMK wrap/unwrap"
  value       = azurerm_role_assignment.databricks_cmk.role_definition_name
}

# ------------------------------------------------------------------
# Keys

# The key-name prefix, derived from local.key_prefix (var.key_name_prefix or the naming module). Depends only on inputs
# and the naming module, NOT on the key resources - so it resolves even when the keys are absent from state, which is
# exactly the situation recover.sh needs when rebuilding state around an existing vault.
output "key_name_prefix" {
  description = "Prefix the three CMK names are built from (<prefix>-adb-services, -adb-dbfs, -adb-disk)"
  value       = local.key_prefix
}

# Key names, built from the prefix rather than read off the key resources, so this stays resolvable when the keys are
# not yet in state (recover.sh reads this before importing them).
output "key_names" {
  description = "Names of the CMKs created in the vault, one per CMK scope"
  value = [
    "${local.key_prefix}-adb-services",
    "${local.key_prefix}-adb-dbfs",
    "${local.key_prefix}-adb-disk",
  ]
}

# Versioned key IDs. Databricks requires a specific key version rather than "latest", so these use the ARM response's
# keyUriWithVersion. Rotating a key therefore requires updating the spokes that consume these - see the rotation runbook.
output "managed_services_key_id" {
  description = "Versioned ID of the managed services CMK"
  value       = azapi_resource.managed_services_key.output.properties.keyUriWithVersion
}

output "dbfs_root_key_id" {
  description = "Versioned ID of the DBFS root CMK"
  value       = azapi_resource.dbfs_root_key.output.properties.keyUriWithVersion
}

output "managed_disk_key_id" {
  description = "Versioned ID of the managed disk CMK"
  value       = azapi_resource.managed_disk_key.output.properties.keyUriWithVersion
}

# The DBFS root CMK is applied by the spoke as an ARM body, which takes the vault URI, key name, and version as separate
# properties rather than as a single versioned URI. Emit the parts here so the spoke does not have to parse the URI.
output "dbfs_root_key_name" {
  description = "Name of the DBFS root CMK, for the spoke's ARM body"
  value       = azapi_resource.dbfs_root_key.name
}

output "dbfs_root_key_version" {
  description = "Version of the DBFS root CMK, for the spoke's ARM body"
  value       = basename(azapi_resource.dbfs_root_key.output.properties.keyUriWithVersion)
}
