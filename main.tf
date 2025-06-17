# Kenisis firehose stream
# Record Transformation Required, called "processing_configuration" in Terraform

data "aws_caller_identity" "current" {}

module "kinesis_firehose_s3_bucket" {
    source            = "git::https://github.info53.com/fitb-enterprise-software/terraform-aws-xqz_s3?ref=v1.2.1"
    bucket            = lower(replace(var.s3_bucket_name, "_", "-"))
    base_environment  = var.base_environment
}

resource "aws_kinesis_firehose_delivery_stream" "kinesis_firehose" {
  name        = "${var.firehose_name}-${var.cloudwatch_group_name}"
  destination = "splunk"


  splunk_configuration {
    hec_endpoint               = var.hec_url
    hec_token                  = jsondecode(aws_secretsmanager_secret_version.splunk_hec_credential_version.secret_string)["SPLUNK_HEC_CREDENTIAL"]
    hec_acknowledgment_timeout = var.hec_acknowledgment_timeout
    hec_endpoint_type          = var.hec_endpoint_type
    s3_backup_mode             = var.s3_backup_mode

    s3_configuration {
      role_arn           = aws_iam_role.kinesis_firehose.arn
      prefix             = var.s3_prefix
      bucket_arn         = module.kinesis_firehose_s3_bucket.arn
      buffering_size     = var.kinesis_firehose_buffer
      buffering_interval = var.kinesis_firehose_buffer_interval
      compression_format = var.s3_compression_format
    }

    processing_configuration {
      enabled = "true"

      processors {
        type = "Lambda"

        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.firehose_lambda_transform.arn}:$LATEST"
        }
        parameters {
          parameter_name  = "RoleArn"
          parameter_value = aws_iam_role.kinesis_firehose.arn
        }
        parameters {
          parameter_name  = "BufferSizeInMBs"
          parameter_value = var.kinesis_firehose_transform_buffer
        }
        parameters {
          parameter_name  = "BufferIntervalInSeconds"
          parameter_value = var.kinesis_firehose_transform_buffer_interval
        }
      }
    }

    cloudwatch_logging_options {
      enabled         = var.enable_fh_cloudwatch_logging
      log_group_name  = aws_cloudwatch_log_group.kinesis_logs.name
      log_stream_name = aws_cloudwatch_log_stream.kinesis_logs.name
    }
  }

  tags = var.tags
}


resource "aws_s3_bucket_server_side_encryption_configuration" "kinesis_firehose_s3_bucket_encryption" {
  bucket = module.kinesis_firehose_s3_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_notification" "trigger_lambda_reingest_event" {
  bucket = module.kinesis_firehose_s3_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.firehose_lambda_reingest.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "${var.s3_prefix}splunk-failed/"
  }

  depends_on = [
    aws_lambda_permission.allow_bucket_to_trigger_reingest
  ]
}

resource "aws_s3_bucket_public_access_block" "kinesis_firehose_s3_bucket" {
  count  = var.s3_bucket_block_public_access_enabled
  bucket = module.kinesis_firehose_s3_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cloudwatch logging group for Kinesis Firehose
resource "aws_cloudwatch_log_group" "kinesis_logs" {
  name              = "/aws/kinesisfirehose/${var.firehose_name}-${var.cloudwatch_group_name}"
  retention_in_days = var.cloudwatch_log_retention

  tags = var.tags
}

# Create the stream
resource "aws_cloudwatch_log_stream" "kinesis_logs" {
  name           = "${var.log_stream_name}-${var.cloudwatch_group_name}"
  log_group_name = aws_cloudwatch_log_group.kinesis_logs.name
}

# Role for the transformation Lambda function attached to the kinesis stream

resource "aws_iam_role" "kinesis_firehose_lambda_transform" {
  name                 = "${var.kinesis_firehose_lambda_transform_role_name}-${var.cloudwatch_group_name}"
  description          = "Role for Lambda function to transform CloudWatch logs into Splunk compatible format"
  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/pubcloud/AppTeamIAMBoundary"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "lambda.amazonaws.com",
          "logs.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY

  tags = var.tags
}

data "aws_iam_policy_document" "lambda_transform_policy_doc" {
  statement {
    actions = [
      "logs:GetLogEvents",
      "logs:ListTagsLogGroup",
    ]

    resources = [
      var.arn_cloudwatch_logs_shippable == "" ?
      "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:*" : var.arn_cloudwatch_logs_shippable
    ]

    effect = "Allow"
  }

  statement {
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]

    resources = [
      aws_kinesis_firehose_delivery_stream.kinesis_firehose.arn,
    ]

    effect = "Allow"
  }

  statement {
    actions = [
      "logs:PutLogEvents",
    ]

    resources = [
      "*",
    ]

    effect = "Allow"
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
    ]

    resources = [
      "*",
    ]

    effect = "Allow"
  }

  statement {
    actions = [
      "logs:CreateLogStream",
    ]

    resources = [
      "*",
    ]

    effect = "Allow"
  }
}

resource "aws_iam_policy" "lambda_transform_policy" {
  name   = "${var.lambda_transform_iam_policy_name}-${var.cloudwatch_group_name}"
  policy = data.aws_iam_policy_document.lambda_transform_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "lambda_transform_policy_role_attachment" {
  role       = aws_iam_role.kinesis_firehose_lambda_transform.name
  policy_arn = aws_iam_policy.lambda_transform_policy.arn
}

# Create the transform lambda function
# The lambda function to transform data from compressed format in Cloudwatch to something Splunk can handle (uncompressed)
resource "aws_lambda_function" "firehose_lambda_transform" {
  function_name    = "${var.lambda_transform_function_name}-${var.cloudwatch_group_name}"
  description      = "Transform data from CloudWatch format to Splunk compatible format"
  filename         = data.archive_file.lambda_transform_function.output_path
  role             = aws_iam_role.kinesis_firehose_lambda_transform.arn
  handler          = "logTransformationProcessor.handler"
  source_code_hash = data.archive_file.lambda_transform_function.output_base64sha256
  runtime          = var.nodejs_runtime
  timeout          = var.lambda_function_timeout
  memory_size      = var.lambda_transform_memory_size

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
  }

  environment {
    variables = {
      "ENABLE_TAG_OVERRIDE" = var.splunk_enable_tag_lookup,
      "SPLUNK_SOURCE"       = var.splunk_default_source,
      "SPLUNK_SOURCE_TYPE"  = var.splunk_default_sourcetype,
      "SPLUNK_HOST"         = var.splunk_default_host,
      "SPLUNK_INDEX"        = var.splunk_default_index,
      "BASE_ENVIRONMENT"    = var.base_environment
    }
  }

  tags = var.tags
}

# kinesis-firehose-cloudwatch-logs-processor.js was taken by copy/paste from the AWS UI.  It is predefined blueprint
# code supplied to AWS by Splunk.
data "archive_file" "lambda_transform_function" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/log-transformation-processor"
  output_path = "${path.module}/lambdas/log-transformation-processor.zip"
}

# Role for the Reingest Lambda function listening to s3 bucket
resource "aws_iam_role" "kinesis_firehose_lambda_reingest" {
  name                 = "${var.kinesis_firehose_lambda_reingest_role_name}-${var.cloudwatch_group_name}"
  description          = "Role for Lambda function to reingest failed logs back into firehose"
  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/pubcloud/AppTeamIAMBoundary"

  assume_role_policy = <<POLICY
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      }
    }
  ],
  "Version": "2012-10-17"
}
POLICY


  tags = var.tags
}

data "aws_iam_policy_document" "lambda_reingest_policy_doc" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "*",
    ]

    effect = "Allow"
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [
      "${module.kinesis_firehose_s3_bucket.arn}/*"
    ]

    effect = "Allow"
  }

  statement {
    actions = [
      "firehose:PutRecordBatch",
    ]

    resources = [
      aws_kinesis_firehose_delivery_stream.kinesis_firehose.arn,
    ]

    effect = "Allow"
  }

}

resource "aws_iam_policy" "lambda_reingest_policy" {
  name   = "${var.lambda_reingest_iam_policy_name}-${var.cloudwatch_group_name}"
  policy = data.aws_iam_policy_document.lambda_reingest_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "lambda_reingest_policy_role_attachment" {
  role       = aws_iam_role.kinesis_firehose_lambda_reingest.name
  policy_arn = aws_iam_policy.lambda_reingest_policy.arn
}

# Create the reingest lambda function
# The lambda function listens for logs added to the splashback s3 bucket and sends them back to the firehose for processing
resource "aws_lambda_function" "firehose_lambda_reingest" {
  function_name    = "${var.lambda_reingest_function_name}-${var.cloudwatch_group_name}"
  description      = "Send failed log transactions in splashback s3 bucket to be reingested by firehose"
  filename         = data.archive_file.lambda_reingest_function.output_path
  role             = aws_iam_role.kinesis_firehose_lambda_reingest.arn
  handler          = "logReingestionProcessor.handler"
  source_code_hash = data.archive_file.lambda_reingest_function.output_base64sha256
  runtime          = var.nodejs_runtime
  timeout          = var.lambda_function_timeout
  memory_size      = var.lambda_reingest_memory_size

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
  }

  environment {
    variables = {
      "FIREHOSE"         = aws_kinesis_firehose_delivery_stream.kinesis_firehose.name,
      "REGION"           = var.region,
      "MAX_REINGEST"     = var.max_reingest_count
      "S3_FAILED_PREFIX" = "${var.s3_prefix}SplashbackRawFailed/"
    }

  }

  tags = var.tags
}

resource "aws_lambda_permission" "allow_bucket_to_trigger_reingest" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.firehose_lambda_reingest.arn
  principal     = "s3.amazonaws.com"
  source_arn    = module.kinesis_firehose_s3_bucket.arn
}

# Reingest lambda archive
data "archive_file" "lambda_reingest_function" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/log-reingestion-processor"
  output_path = "${path.module}/lambdas/log-reingestion-processor.zip"
}

# Role for Kenisis Firehose
resource "aws_iam_role" "kinesis_firehose" {
  name                 = "${var.kinesis_firehose_role_name}-${var.cloudwatch_group_name}"
  description          = "IAM Role for Kenisis Firehose"
  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/pubcloud/AppTeamIAMBoundary"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Principal": {
        "Service": "firehose.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Effect": "Allow"
    }
  ]
}
POLICY


  tags = var.tags
}

data "aws_iam_policy_document" "kinesis_firehose_policy_document" {
  statement {
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]

    resources = [
      module.kinesis_firehose_s3_bucket.arn,
      "${module.kinesis_firehose_s3_bucket.arn}/*",
    ]

    effect = "Allow"
  }

  statement {
    actions = [
      "lambda:InvokeFunction",
      "lambda:GetFunctionConfiguration",
    ]

    resources = [
      "${aws_lambda_function.firehose_lambda_transform.arn}:$LATEST",
    ]
  }

  statement {
    actions = [
      "logs:PutLogEvents",
    ]

    resources = [
      aws_cloudwatch_log_group.kinesis_logs.arn,
      aws_cloudwatch_log_stream.kinesis_logs.arn,
    ]

    effect = "Allow"
  }
}

resource "aws_iam_policy" "kinesis_firehose_iam_policy" {
  name   = "${var.kinesis_firehose_iam_policy_name}-${var.cloudwatch_group_name}"
  policy = data.aws_iam_policy_document.kinesis_firehose_policy_document.json
}

resource "aws_iam_role_policy_attachment" "kinesis_fh_role_attachment" {
  role       = aws_iam_role.kinesis_firehose.name
  policy_arn = aws_iam_policy.kinesis_firehose_iam_policy.arn
}

resource "aws_secretsmanager_secret" "splunk_hec_credential" {
  name        = "${var.base_environment}-${var.cloudwatch_group_name}-splunk-hec-credential"
  description = "Creating Secret Manager for Splunk HEC token"
}

resource "aws_secretsmanager_secret_version" "splunk_hec_credential_version" {
  secret_id     = aws_secretsmanager_secret.splunk_hec_credential.id
  secret_string = jsonencode({
    SPLUNK_HEC_CREDENTIAL = "bfb9fca5-c44d-4ab8-a55d-4d74473f6a82"
  })
}

# handle the sensitivity of the hec_token variable
# data "aws_secretsmanager_secret" "splunk_hec_credential" {
#   arn = var.arn_hec_credential_secret
# }

# data "aws_secretsmanager_secret_version" "splunk_hec_credential_version" {
#  secret_id = data.aws_secretsmanager_secret.splunk_hec_credential.id
# }
