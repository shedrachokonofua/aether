resource "aws_accessanalyzer_analyzer" "unused_access_analyzer" {
  analyzer_name = "unused-access-analyzer"
  type          = "ACCOUNT_UNUSED_ACCESS"

  configuration {
    unused_access {
      unused_access_age = 90
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_accessanalyzer_analyzer" "account_external_access_analyzer" {
  analyzer_name = "account-external-access-analyzer"
  type          = "ACCOUNT"

  lifecycle {
    prevent_destroy = true
  }
}
