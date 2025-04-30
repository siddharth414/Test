provider "aws" {
  region = "us-east-1"  # Set to your AWS region
}

# Reference to existing S3 bucket
data "aws_s3_bucket" "firehose_backup" {
  bucket = var.s3_bucket_name
}

# IAM role for Kinesis Firehose
resource "aws_iam_role" "firehose_role" {
  name = "firehose_to_splunk_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "firehose.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

# IAM policy to allow Firehose to access S3
resource "aws_iam_policy" "firehose_policy" {
  name = "firehose_splunk_policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:AbortMultipartUpload"
        ],
        Resource = [
          data.aws_s3_bucket.firehose_backup.arn,
          "${data.aws_s3_bucket.firehose_backup.arn}/*"
        ]
      }
    ]
  })
}

# Attach IAM policy to Firehose role
resource "aws_iam_role_policy_attachment" "attach_firehose_policy" {
  role       = aws_iam_role.firehose_role.name
  policy_arn = aws_iam_policy.firehose_policy.arn
}

# Kinesis Firehose Delivery Stream for Splunk with S3 backup
resource "aws_kinesis_firehose_delivery_stream" "to_splunk" {
  name        = "cw-to-splunk-firehose"
  destination = "splunk"

  splunk_configuration {
    hec_endpoint       = var.splunk_hec_endpoint
    hec_token          = var.splunk_hec_token
    hec_endpoint_type  = "Raw"
    s3_backup_mode     = "FailedEventsOnly"
    retry_duration     = 300

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/to_splunk"
      log_stream_name = "splunk_delivery"
    }
  }

  s3_configuration {
    role_arn           = aws_iam_role.firehose_role.arn
    bucket_arn         = data.aws_s3_bucket.firehose_backup.arn
    buffer_size        = 5
    buffer_interval    = 300
    compression_format = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/to_s3"
      log_stream_name = "s3_backup"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.attach_firehose_policy
  ]
}

# CloudWatch Log Group for source logs (replace with your Log Group name)
resource "aws_cloudwatch_log_group" "log_group" {
  name = var.log_group_name
}

# CloudWatch Logs Subscription Filter to send logs to Firehose
resource "aws_cloudwatch_log_subscription_filter" "firehose_subscription" {
  name            = "firehose-subscription"
  log_group_name  = aws_cloudwatch_log_group.log_group.name
  filter_pattern  = ""  # Optionally, define a filter pattern
  destination_arn = aws_kinesis_firehose_delivery_stream.to_splunk.arn
  role_arn        = aws_iam_role.firehose_role.arn

  depends_on = [
    aws_kinesis_firehose_delivery_stream.to_splunk  # Ensure Firehose stream is created before subscription
  ]
}
