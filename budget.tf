resource "aws_budgets_budget" "prod_monthly_budget" {
  name              = "Gen AI - Prod - Monthly budget"
  budget_type       = "COST"
  limit_amount      = "8000"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  start_date        = "2025-04-01_00:00"

  cost_filters = {}
}

resource "aws_budgets_budget_action" "alert_85_actual" {
  budget_name        = aws_budgets_budget.prod_monthly_budget.name
  action_type        = "NOTIFICATION"
  notification_type  = "ACTUAL"
  threshold_type     = "PERCENTAGE"
  threshold          = 85

  subscribers {
    subscription_type = "EMAIL"
    address           = "your-alert-email@example.com"
  }
}

resource "aws_budgets_budget_action" "alert_100_forecasted" {
  budget_name        = aws_budgets_budget.prod_monthly_budget.name
  action_type        = "NOTIFICATION"
  notification_type  = "FORECASTED"
  threshold_type     = "PERCENTAGE"
  threshold          = 100

  subscribers {
    subscription_type = "EMAIL"
    address           = "your-alert-email@example.com"
  }
}

resource "aws_budgets_budget_action" "alert_100_actual" {
  budget_name        = aws_budgets_budget.prod_monthly_budget.name
  action_type        = "NOTIFICATION"
  notification_type  = "ACTUAL"
  threshold_type     = "PERCENTAGE"
  threshold          = 100

  subscribers {
    subscription_type = "EMAIL"
    address           = "your-alert-email@example.com"
  }
}
