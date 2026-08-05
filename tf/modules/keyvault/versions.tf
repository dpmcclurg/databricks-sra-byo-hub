terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=4.0.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">=2.0"
    }
    # Keys are created through ARM so that key creation is not subject to the vault's data-plane firewall
    azapi = {
      source  = "Azure/azapi"
      version = ">=2.0"
    }
  }
  required_version = ">=1.9.8"
}
