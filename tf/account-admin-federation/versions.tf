terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~>1.81"
    }
  }
  required_version = "~>1.11"

  # Optional, one-time, per-landing-zone setup - run by a HUMAN Databricks account admin. Small enough to keep on local
  # state; there is nothing here another layer depends on at apply time (the spoke only needs the resulting client ID,
  # copied into its var file). Add a remote backend if you prefer to track it.
}
