terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>4.29"
    }
  }
  required_version = "~>1.11"

  # Like the platform layer, this bootstrap state is a long-lived, shared asset: it owns the identities every pipeline
  # authenticates as and the storage account that holds all other layers' state. Losing it is worse than losing a spoke.
  # Configure a versioned, locking remote backend before the first real apply.
  #
  # Chicken-and-egg: this layer CREATES the state storage account, so its own first apply cannot already use it. Run the
  # first apply with local state (the foundational identity described in the README), then migrate this state into the
  # account it just created with `terraform init -migrate-state` and the block below.
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-cicd-bootstrap"
  #   storage_account_name = "sttfstate<nonprod|prod>"
  #   container_name       = "tfstate"
  #   key                  = "bootstrap.tfstate"
  #   use_azuread_auth     = true
  # }
}
