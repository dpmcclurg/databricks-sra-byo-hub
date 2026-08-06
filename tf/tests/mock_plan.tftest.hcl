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
  # Pinned to the default explicitly, because terraform test auto-loads terraform.tfvars from the configuration directory.
  # A deployment that switches the peering off must not silently disable it for every run that asserts on it. The one run
  # that exercises false overrides this locally.
  create_hub_peering = true

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

    # Use existing resource group. The flag is required alongside the name, not optional - without it the name is ignored
    # and the apply fails on a resource group that already exists.
    create_workspace_resource_group = false
    existing_resource_group_name    = "rg-test"

    existing_ncc_id            = "mock-ncc-id"
    existing_ncc_name          = "mock-ncc"
    existing_network_policy_id = "mock-policy-id"
  }

  assert {
    condition     = length(azurerm_resource_group.spoke) == 0
    error_message = "No resource group should be created when create_workspace_resource_group is false"
  }
}

# The expected production shape: the network team creates the resource group, the VNet, its subnets, and the hub peering
# before this configuration runs, because peering a spoke to the hub needs permissions on the hub network that the
# Databricks provisioner does not hold. This spoke then reuses that resource group and that VNet.
#
# tf/platform runs between the two, placing the shared vault's private endpoint into the pre-existing privatelink subnet.
run "plan_test_prebuilt_network_and_resource_group" {
  state_key = "prebuilt_network_and_rg"
  command   = plan
  variables {
    resource_suffix = "prebuilt"

    # Both created ahead of this apply by the network team
    create_workspace_resource_group = false
    existing_resource_group_name    = "rg-prebuilt"
    create_workspace_vnet           = false
    workspace_vnet                  = null

    existing_workspace_vnet = {
      network_configuration = {
        virtual_network_id                                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prebuilt/providers/Microsoft.Network/virtualNetworks/vnet-prebuilt"
        private_subnet_id                                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prebuilt/providers/Microsoft.Network/virtualNetworks/vnet-prebuilt/subnets/container"
        public_subnet_id                                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prebuilt/providers/Microsoft.Network/virtualNetworks/vnet-prebuilt/subnets/host"
        private_subnet_network_security_group_association_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prebuilt/providers/Microsoft.Network/virtualNetworks/vnet-prebuilt/subnets/container"
        public_subnet_network_security_group_association_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prebuilt/providers/Microsoft.Network/virtualNetworks/vnet-prebuilt/subnets/host"
        private_endpoint_subnet_id                           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prebuilt/providers/Microsoft.Network/virtualNetworks/vnet-prebuilt/subnets/privatelink"
      }
      dns_zone_ids = {
        backend = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prebuilt/providers/Microsoft.Network/privateDnsZones/privatelink.azuredatabricks.net"
        dfs     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prebuilt/providers/Microsoft.Network/privateDnsZones/privatelink.dfs.core.windows.net"
        blob    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prebuilt/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
      }
    }

    existing_ncc_id            = "mock-ncc-id"
    existing_ncc_name          = "mock-ncc"
    existing_network_policy_id = "mock-policy-id"
  }

  # Neither the resource group nor the VNet is created - both already exist
  assert {
    condition     = length(azurerm_resource_group.spoke) == 0
    error_message = "No resource group should be created when create_workspace_resource_group is false"
  }

  assert {
    condition     = length(module.spoke_network) == 0
    error_message = "No VNet should be created when create_workspace_vnet is false"
  }

  # The workspace lands in the pre-existing resource group the network team built
  assert {
    condition     = module.spoke_workspace.resource_group_name == "rg-prebuilt"
    error_message = "The workspace should deploy into the pre-existing resource group"
  }

  # CMK still works with no networking of its own in this layer, because the private endpoint is the platform's
  assert {
    condition     = module.spoke_workspace.workspace.managed_services_cmk_key_vault_key_id == var.platform_cmk.managed_services_key_id
    error_message = "CMK should be configured from the shared platform vault even with fully pre-built networking"
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

# Create the spoke VNet but not the peering. This is the case where the provisioner can build the spoke network but has no
# Microsoft.Network/virtualNetworks/peer/action on the hub - typically a hub in another subscription or tenant - so ARM
# would fail the peering with LinkedAuthorizationFailed even though only the spoke half is being created.
run "plan_test_vnet_without_hub_peering" {
  state_key = "vnet_no_peering"
  command   = plan
  variables {
    resource_suffix    = "nopeer"
    create_hub_peering = false

    workspace_vnet = {
      cidr     = "10.0.5.0/24"
      new_bits = null
    }

    existing_ncc_id            = "mock-ncc-id"
    existing_network_policy_id = "mock-policy-id"

    # Still supplied so the handoff outputs can name the hub, though nothing peers to it in this run
    existing_hub_vnet = {
      vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-external-hub/providers/Microsoft.Network/virtualNetworks/vnet-external-hub"
    }
  }

  # The VNet is still created - that is the whole point of this flag versus create_workspace_vnet = false
  assert {
    condition     = length(module.spoke_network) == 1
    error_message = "The spoke VNet should still be created when only the peering is skipped"
  }

  assert {
    condition     = length(module.spoke_network[0].peering_names) == 0
    error_message = "No peering should be created when create_hub_peering is false"
  }

  # The handoff output must say the spoke half is outstanding as well, since Terraform created neither
  assert {
    condition     = output.hub_peering_required.spoke_peering_required
    error_message = "The handoff output should report that the spoke half of the peering is also outstanding"
  }

  # use_remote_gateways is what propagates the hub gateway's on-premises routes. Omitting it when creating the peering by
  # hand costs all on-premises reachability for classic compute, silently, so the handoff must state it.
  #
  # Asserted on the structured output rather than on hub_peering_command: that command string interpolates the generated
  # VNet name and so is unknown at plan time, and switching this run to apply fails elsewhere - the mocked NSG ID is not a
  # parseable ARM resource ID. The command text is rendered from these same values.
  assert {
    condition     = output.hub_peering_required.spoke_required_settings.use_remote_gateways
    error_message = "The spoke-side handoff must require use_remote_gateways, or gateway transit propagates no routes"
  }

  # And the hub half still has to allow the transit that the spoke half consumes
  assert {
    condition     = output.hub_peering_required.required_settings.allow_gateway_transit
    error_message = "The hub-side handoff must require allow_gateway_transit"
  }
}

# A hub VNet is only needed to peer to. With both the VNet and the peering out of scope, the deployment should not have to
# name a hub network it never touches - which is exactly the case when that hub is in an inaccessible subscription.
run "plan_test_no_hub_vnet_supplied" {
  state_key = "no_hub_vnet"
  command   = plan
  variables {
    resource_suffix    = "nohub"
    create_hub_peering = false
    existing_hub_vnet  = null

    create_workspace_resource_group = false
    existing_resource_group_name    = "rg-nohub"
    create_workspace_vnet           = false
    workspace_vnet                  = null

    existing_workspace_vnet = {
      network_configuration = {
        virtual_network_id                                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-nohub/providers/Microsoft.Network/virtualNetworks/vnet-nohub"
        private_subnet_id                                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-nohub/providers/Microsoft.Network/virtualNetworks/vnet-nohub/subnets/container"
        public_subnet_id                                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-nohub/providers/Microsoft.Network/virtualNetworks/vnet-nohub/subnets/host"
        private_subnet_network_security_group_association_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-nohub/providers/Microsoft.Network/virtualNetworks/vnet-nohub/subnets/container"
        public_subnet_network_security_group_association_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-nohub/providers/Microsoft.Network/virtualNetworks/vnet-nohub/subnets/host"
        private_endpoint_subnet_id                           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-nohub/providers/Microsoft.Network/virtualNetworks/vnet-nohub/subnets/privatelink"
      }
      dns_zone_ids = {
        backend = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-nohub/providers/Microsoft.Network/privateDnsZones/privatelink.azuredatabricks.net"
        dfs     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-nohub/providers/Microsoft.Network/privateDnsZones/privatelink.dfs.core.windows.net"
        blob    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-nohub/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
      }
    }

    existing_ncc_id            = "mock-ncc-id"
    existing_network_policy_id = "mock-policy-id"
  }

  # The hub outputs degrade to null rather than failing on a null lookup
  assert {
    condition     = output.hub_peering_required == null
    error_message = "The hub handoff output should be null when no hub VNet is supplied"
  }

  assert {
    condition     = output.hub_peering_command == null
    error_message = "The hub peering command should be null when no hub VNet is supplied"
  }

  # The workspace is still fully built - the hub network was only ever needed to peer to
  assert {
    condition     = module.spoke_workspace.workspace.managed_services_cmk_key_vault_key_id == var.platform_cmk.managed_services_key_id
    error_message = "The workspace should deploy normally with no hub VNet supplied"
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

  # Neither the vault nor the private path to it is created here - both belong to the platform layer. This spoke records
  # which vault its keys came from and nothing more.
  assert {
    condition     = output.spoke_keyvault.key_vault_id == var.platform_cmk.key_vault_id
    error_message = "The spoke should report the shared platform vault it consumes keys from"
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
