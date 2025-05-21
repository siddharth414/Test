resource "terraform_data" "year" {
  input = formatdate("YYYY", timestamp())
}

resource "aws_budgets_budget" "this" {
  name              = "${terraform_data.year.input}_${var.budget_name}"
  budget_type       = "COST"
  time_unit         = "MONTHLY"
  limit_amount      = var.budget_limit
  limit_unit        = "USD"
  time_period_start = "${terraform_data.year.input}-04-01_00:00"
  time_period_end   = "${terraform_data.year.input}-12-31_23:59"

  cost_filter {
    name   = "CostCategory"
    values = ["BudgetCostCategories${var.budget_name}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 85
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }
}


variable "budget_name" {
  description = "Base name of the budget (without year prefix)"
  type        = string
  default     = "genai-prod-monthly"
}

variable "budget_limit" {
  description = "Monthly budget limit in USD"
  type        = number
  default     = 8000
}

variable "notification_email" {
  description = "Email address to receive budget alerts"
  type        = string
  default     = "your-alert-email@example.com"
}
