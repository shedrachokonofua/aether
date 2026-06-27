variable "billing_account_id" {
  type        = string
  description = "Google Cloud Billing Account ID"
  default     = ""
}

resource "google_billing_budget" "budget" {
  count           = var.billing_account_id != "" ? 1 : 0
  billing_account = var.billing_account_id
  display_name    = "aether-gcp-spend-alert"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = "1" # $1.00 budget
    }
  }

  threshold_rules {
    threshold_percent = 0.5 # Alert at 50c
  }

  threshold_rules {
    threshold_percent = 0.9 # Alert at 90c
  }

  threshold_rules {
    threshold_percent = 1.0 # Alert at $1.00
  }
}
