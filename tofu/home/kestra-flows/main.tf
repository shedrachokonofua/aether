# Aether-owned Kestra flow IaC (separate from Helm platform state and from Inquest).
# Backend key: kestra-flows.tfstate in the shared S3 remote backend.
#
# Auth: task login (Bao) then export VAULT_TOKEN; AWS creds from task login.
# Apply: task tofu:kestra-flows:apply

terraform {
  required_version = ">= 1.6"

  backend "s3" {
    # Partial config — filled by -backend-config=config/tofu-state.config plus key override.
  }

  required_providers {
    kestra = {
      source  = "kestra-io/kestra"
      version = "~> 1.0.2"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.7.0"
    }
  }
}

provider "vault" {
  address          = "https://bao.home.shdr.ch"
  skip_child_token = true
}

ephemeral "vault_kv_secret_v2" "kestra" {
  mount = "kv"
  name  = "aether/kestra"
}

variable "kestra_url" {
  type        = string
  description = "Kestra API base URL"
  default     = "https://kestra.home.shdr.ch"
}

provider "kestra" {
  url      = coalesce(var.kestra_url, ephemeral.vault_kv_secret_v2.kestra.data["url"])
  username = ephemeral.vault_kv_secret_v2.kestra.data["basic_auth_username"]
  password = ephemeral.vault_kv_secret_v2.kestra.data["basic_auth_password"]
}

resource "kestra_flow" "estate_scan_home" {
  namespace = "aether.estate"
  flow_id   = "estate-scan-home"

  content = file("${path.module}/../../../kestra/flows/estate-scan-home.yaml")
}
