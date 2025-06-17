resource "aws_cloudwatch_log_group" "reingest_logs" {
  name = "/aws/lambda/${aws_lambda_function.firehose_lambda_reingest.function_name}"
  retention_in_days = var.cloudwatch_log_retention
  tags = var.tags
}
