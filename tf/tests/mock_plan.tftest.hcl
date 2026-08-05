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
    existing_cmk_ids = {
      key_vault_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.KeyVault/vaults/mock-kv"
      managed_disk_key_id     = "https://example-keyvault.vault.azure.net/keys/example/fdf067c93bbb4b22bff4d8b7a9a56217"
      managed_services_key_id = "https://example-keyvault.vault.azure.net/keys/example/fdf067c93bbb4b22bff4d8b7a9a56217"
    }

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
    existing_cmk_ids = {
      key_vault_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.KeyVault/vaults/mock-kv"
      managed_disk_key_id     = "https://example-keyvault.vault.azure.net/keys/example/fdf067c93bbb4b22bff4d8b7a9a56217"
      managed_services_key_id = "https://example-keyvault.vault.azure.net/keys/example/fdf067c93bbb4b22bff4d8b7a9a56217"
    }
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
    existing_cmk_ids = {
      key_vault_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.KeyVault/vaults/mock-kv"
      managed_disk_key_id     = "https://example-keyvault.vault.azure.net/keys/example/fdf067c93bbb4b22bff4d8b7a9a56217"
      managed_services_key_id = "https://example-keyvault.vault.azure.net/keys/example/fdf067c93bbb4b22bff4d8b7a9a56217"
    }

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

  # With CMK disabled there is no vault to create, whatever cmk_source says
  assert {
    condition     = length(module.spoke_keyvault) == 0
    error_message = "No Key Vault should be created when cmk_enabled is false"
  }
}

# The default CMK path: the spoke creates its own Key Vault rather than being handed one. Note that no existing_cmk_ids
# is supplied here - that is the point of cmk_source = "create".
run "plan_test_cmk_create_in_spoke" {
  state_key = "cmk_create"
  command   = plan
  variables {
    resource_suffix = "spokecmk"
    cmk_enabled     = true
    cmk_source      = "create"

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

  assert {
    condition     = length(module.spoke_keyvault) == 1
    error_message = "A Key Vault should be created when cmk_source is \"create\""
  }

  # Purge protection cannot be disabled once set, and a purged key would permanently break the workspace's compute
  assert {
    condition     = module.spoke_keyvault[0].purge_protection_enabled
    error_message = "Purge protection must be enabled on the spoke Key Vault"
  }

  # The vault must be closed to the public internet, with no IP exceptions
  assert {
    condition     = module.spoke_keyvault[0].public_network_access_enabled == false
    error_message = "The spoke Key Vault must not allow public network access"
  }

  assert {
    condition     = module.spoke_keyvault[0].network_acls_default_action == "Deny"
    error_message = "The spoke Key Vault firewall must deny by default"
  }

  # Both CMK consumers - the Databricks control plane and the Disk Encryption Set - sit outside the VNet and reach the
  # vault via the trusted-services bypass, not the private endpoint. Losing this breaks cluster startup.
  assert {
    condition     = module.spoke_keyvault[0].network_acls_bypass == "AzureServices"
    error_message = "The spoke Key Vault must allow the AzureServices bypass, which is what permits CMK access"
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
