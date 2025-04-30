variable "splunk_hec_endpoint" {
  description = "Splunk HEC endpoint URL"
  type        = string
}

variable "splunk_hec_token" {
  description = "Splunk HEC token"
  type        = string
  sensitive   = true
}

variable "s3_bucket_name" {
  description = "S3 bucket name for failed delivery backup"
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch Log Group name"
  type        = string
}
