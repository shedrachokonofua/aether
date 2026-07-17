# Billing tripwire for the Pay-As-You-Go upgrade: the estate's OCI footprint
# is Always-Free-only (A1 4/24 + E2.1.Micro + boot volumes under the 200GB
# allowance), so ANY actual spend is a bug. Budget is the $1 floor OCI allows;
# the ACTUAL alert fires at 1% of it ($0.01) - i.e. on the first billed cent.
resource "oci_budget_budget" "aether" {
  compartment_id = var.tenancy_ocid
  amount         = 1
  reset_period   = "MONTHLY"
  display_name   = "aether-zero-spend-tripwire"
  description    = "Always-Free estate: any actual spend is unintended"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]
}

resource "oci_budget_alert_rule" "actual_spend" {
  budget_id      = oci_budget_budget.aether.id
  type           = "ACTUAL"
  threshold      = 1
  threshold_type = "PERCENTAGE"
  display_name   = "any-actual-spend"
  message        = "OCI billed actual money to the aether tenancy. The estate is Always-Free-only; find and kill the paid resource."
  recipients     = var.notification_email
}

resource "oci_budget_alert_rule" "forecast_spend" {
  budget_id      = oci_budget_budget.aether.id
  type           = "FORECAST"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  display_name   = "forecast-over-budget"
  message        = "OCI forecasts spend over the $1 tripwire budget for the aether tenancy."
  recipients     = var.notification_email
}

variable "notification_email" {
  type        = string
  description = "Recipient for budget alerts (same address the AWS budget uses)"
}
