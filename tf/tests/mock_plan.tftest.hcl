test {
  parallel = true
}

# The below mocked providers have mock_data blocks anywhere a properly formatted GUID is used in the configuration
# (i.e. access policies, role assignments, etc.)
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000000"
      object_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_data "azurerm_subscription" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "databricks" {
  mock_data "databricks_user" {
    defaults = {
      id = 0
    }
  }
}

# Stands in for the platform layer's spoke_tfvars_snippet output. In a real deployment these come from tf/platform.
# Declared at file scope so every run inherits it; runs that need it by name reference var.platform_cmk.
variables {
  platform_cmk = {
    key_vault_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.KeyVault/vaults/mock-kv"
    key_vault_uri = "https://mock-kv.vault.azure.net/"

    managed_services_key_id = "https://mock-kv.vault.azure.net/keys/mock-adb-services/fdf067c93bbb4b22bff4d8b7a9a56217"
    managed_disk_key_id     = "https://mock-kv.vault.azure.net/keys/mock-adb-disk/fdf067c93bbb4b22bff4d8b7a9a56217"

    dbfs_root_key_name    = "mock-adb-dbfs"
    dbfs_root_key_version = "fdf067c93bbb4b22bff4d8b7a9a56217"
  }
}

run "plan_test_defaults" {
  state_key = "defaults"
  command   = plan
}

run "plan_test_byo_hub_with_spoke" {
  state_key = "byo_hub_with_spoke"
  command   = plan
  variables {
    databricks_metastore_id = "00000000-0000-0000-0000-000000000000"
    resource_suffix         = "spoke"
    tags                    = { example = "value" }

    # Create SRA-managed workspace vnet
    workspace_vnet = {
      cidr     = "10.0.2.0/24"
      new_bits = null
    }

    # BYO hub integration
    # Note: spoke.tf references existing_hub_vnet which may need to be defined
    existing_ncc_id            = "mock-ncc-id"
    existing_ncc_name          = "mock-ncc"
    existing_network_policy_id = "mock-policy-id"

    # Provide existing hub vnet info if needed
    existing_hub_vnet = {
      vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-external-hub/providers/Microsoft.Network/virtualNetworks/vnet-external-hub"
    }
  }
}

run "plan_test_byo_hub_byo_network" {
  state_key = "byo_hub_byo_network"
  command   = plan
  variables {
    databricks_metastore_id = "00000000-0000-0000-0000-000000000000"
    create_workspace_vnet   = false
    resource_suffix         = "spokenonet"
    tags                    = { test = "value" }
    workspace_vnet          = null
    # BYO workspace vnet
    existing_workspace_vnet = {
      network_configuration = {
        virtual_network_id                                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test"
        private_subnet_id                                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/container"
        public_subnet_id                                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/host"
        private_subnet_network_security_group_association_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/container"
        public_subnet_network_security_group_association_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/host"
        private_endpoint_subnet_id                           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/privatelink"
      }
      dns_zone_ids = {
        backend = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/privateDnsZones/privatelink.azuredatabricks.net"
        dfs     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/privateDnsZones/privatelink.dfs.core.windows.net"
        blob    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
      }
    }

    # Use existing resource group
    existing_resource_group_name = "rg-test"

    existing_ncc_id            = "mock-ncc-id"
    existing_ncc_name          = "mock-ncc"
    existing_network_policy_id = "mock-policy-id"
  }
}

# BYO hub with no Azure Firewall: on-premises and P2S reachability for classic compute comes from gateway transit, not
# from a route table. The spoke peering must set use_remote_gateways so Azure propagates the hub gateway's learned
# routes into the spoke VNet as system routes. No route table or UDRs are created.
run "plan_test_byo_hub_no_firewall" {
  state_key = "byo_hub_no_firewall"
  command   = plan
  variables {
    databricks_metastore_id = "00000000-0000-0000-0000-000000000000"
    resource_suffix         = "spokenofw"
    tags                    = { example = "value" }

    workspace_vnet = {
      cidr     = "10.0.3.0/24"
      new_bits = null
    }

    existing_ncc_id            = "mock-ncc-id"
    existing_ncc_name          = "mock-ncc"
    existing_network_policy_id = "mock-policy-id"

    existing_hub_vnet = {
      vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-external-hub/providers/Microsoft.Network/virtualNetworks/vnet-external-hub"
    }
  }

  # use_remote_gateways is what makes the hub gateway's routes (on-premises prefixes and the P2S client pool) propagate
  # into this VNet. Without it there is no path to on-premises at all, since no UDRs are created.
  assert {
    condition     = module.spoke_network[0].hub_peering_uses_remote_gateways
    error_message = "Spoke peering must set use_remote_gateways so gateway transit propagates on-premises routes"
  }

  # No route table is created - propagated system routes are relied on instead
  assert {
    condition     = length(module.spoke_network[0].route_table_ids) == 0
    error_message = "No route table should be created in the no-firewall topology"
  }
}

run "plan_test_cmk_disabled" {
  state_key = "cmk_disabled"
  command   = plan
  variables {
    resource_suffix = "nocmk"
    cmk_enabled     = false
    workspace_vnet = {
      cidr     = "10.1.0.0/20"
      new_bits = null
    }
  }

  # With CMK disabled there is no vault to reach, so no private endpoint or DNS zone for one
  assert {
    condition     = length(module.spoke_keyvault_access) == 0
    error_message = "No Key Vault private endpoint should be created when cmk_enabled is false"
  }

  # The workspace should fall back to platform-managed keys on every scope rather than half-configuring CMK
  assert {
    condition     = module.spoke_workspace.workspace.customer_managed_key_enabled == false
    error_message = "customer_managed_key_enabled should be false when cmk_enabled is false"
  }

  assert {
    condition     = module.spoke_workspace.workspace.managed_services_cmk_key_vault_key_id == null
    error_message = "No managed services CMK should be set when cmk_enabled is false"
  }

  assert {
    condition     = module.spoke_workspace.workspace.managed_disk_cmk_key_vault_key_id == null
    error_message = "No managed disk CMK should be set when cmk_enabled is false"
  }

  assert {
    condition     = module.spoke_workspace.workspace.infrastructure_encryption_enabled == false
    error_message = "Infrastructure encryption is tied to cmk_enabled and should be false here"
  }
}

# The CMK path: keys come from the shared platform vault in tf/platform, and this spoke consumes them. This replaces the
# old plan_test_cmk_create_in_spoke - the vault's own posture is now asserted in tf/platform/tests, since it is created
# there.
run "plan_test_cmk_from_platform" {
  state_key = "cmk_from_platform"
  command   = plan
  variables {
    resource_suffix = "spokecmk"
    cmk_enabled     = true

    workspace_vnet = {
      cidr     = "10.1.0.0/20"
      new_bits = null
    }

    existing_ncc_id            = "mock-ncc-id"
    existing_ncc_name          = "mock-ncc"
    existing_network_policy_id = "mock-policy-id"

    existing_hub_vnet = {
      vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-external-hub/providers/Microsoft.Network/virtualNetworks/vnet-external-hub"
    }
  }

  # No vault is created here - it belongs to the platform layer. Only a private path to it.
  assert {
    condition     = length(module.spoke_keyvault_access) == 1
    error_message = "A Key Vault private endpoint should be created when CMK is enabled and create_key_vault_private_endpoint is true"
  }

  # One zone per spoke, in this spoke's resource group. A single shared zone would collide on the A-record name, since
  # every spoke's endpoint targets the same vault - see modules/keyvault_access/main.tf.
  assert {
    condition     = module.spoke_keyvault_access[0].private_dns_zone_name == "privatelink.vaultcore.azure.net"
    error_message = "The spoke should own a privatelink.vaultcore.azure.net zone for the shared vault"
  }

  # The two scopes set as typed workspace attributes should carry exactly the platform's versioned key URIs
  assert {
    condition     = module.spoke_workspace.workspace.managed_services_cmk_key_vault_key_id == var.platform_cmk.managed_services_key_id
    error_message = "The workspace should use the platform's managed services key"
  }

  assert {
    condition     = module.spoke_workspace.workspace.managed_disk_cmk_key_vault_key_id == var.platform_cmk.managed_disk_key_id
    error_message = "The workspace should use the platform's managed disk key"
  }

  # Azure Databricks has no auto-rotation flag for managed services, but does for managed disk, and this template opts in
  assert {
    condition     = module.spoke_workspace.workspace.managed_disk_cmk_rotation_to_latest_version_enabled
    error_message = "Managed disk CMK should be set to rotate to the latest key version"
  }

  assert {
    condition     = module.spoke_workspace.workspace.infrastructure_encryption_enabled
    error_message = "Infrastructure encryption should be enabled alongside CMK"
  }
}

# Access connectors can be moved to the platform security resource group. Placement only - each spoke still gets its own
# pair, so a Unity Catalog credential cannot reach another spoke's storage.
run "plan_test_connectors_in_security_rg" {
  state_key = "connectors_security_rg"
  command   = plan
  variables {
    resource_suffix                        = "connrg"
    place_access_connectors_in_security_rg = true
    security_resource_group_name           = "rg-dbx-prod-security"

    workspace_vnet = {
      cidr     = "10.1.0.0/20"
      new_bits = null
    }
  }

  assert {
    condition     = module.spoke_workspace.default_storage_access_connector_resource_group == "rg-dbx-prod-security"
    error_message = "The workspace default-storage access connector should be created in the security resource group"
  }

  assert {
    condition     = module.spoke_catalog.access_connector_resource_group == "rg-dbx-prod-security"
    error_message = "The Unity Catalog access connector should be created in the security resource group"
  }

  # The workspace itself must stay in the workspace resource group
  assert {
    condition     = module.spoke_workspace.resource_group_name != "rg-dbx-prod-security"
    error_message = "Only the access connectors move - the workspace stays in its own resource group"
  }
}

run "plan_test_enhanced_security" {
  state_key = "enhanced_security"
  command   = plan
  variables {
    resource_suffix = "secure"
    workspace_vnet = {
      cidr     = "10.1.0.0/20"
      new_bits = null
    }
    workspace_security_compliance = {
      automatic_cluster_update_enabled      = true
      compliance_security_profile_enabled   = true
      compliance_security_profile_standards = ["HIPAA", "PCI_DSS"]
      enhanced_security_monitoring_enabled  = true
    }
  }
}

run "plan_test_byo_resource_group" {
  state_key = "byo_rg"
  command   = plan
  variables {
    create_workspace_resource_group = false
    existing_resource_group_name    = "rg-existing"
    resource_suffix                 = "byorg"
    workspace_vnet = {
      cidr     = "10.1.0.0/20"
      new_bits = null
    }
  }
}

run "plan_test_name_overrides" {
  state_key = "name_overrides"
  command   = plan
  variables {
    resource_suffix = "custom"
    workspace_vnet = {
      cidr     = "10.1.0.0/20"
      new_bits = null
    }
    workspace_name_overrides = {
      databricks_workspace = "my-custom-workspace"
      private_endpoint     = "pe-custom-databricks"
    }
  }
}

run "plan_test_custom_subnet_sizing" {
  state_key = "custom_subnets"
  command   = plan
  variables {
    resource_suffix = "customsubs"
    workspace_vnet = {
      cidr     = "10.1.0.0/20"
      new_bits = 3
    }
  }
}
