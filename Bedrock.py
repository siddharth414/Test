import boto3
import json

# ===== CONFIGURATION =====
AWS_PROFILE = "your-aws-profile-name"  # Update this
BEDROCK_ROLE_ARN = "arn:aws:iam::123456789012:role/your-bedrock-role"  # Update this
GUARDRAIL_ID = "your-guardrail-id"  # Update this
GUARDRAIL_VERSION = "1"  # Update this if needed
MODEL_ID = "anthropic.claude-3-sonnet-20240229-v1:0"  # Or Opus/Haiku
REGION = "us-east-1"
PROMPT_TEXT = "Hi"

# ===== SETUP SESSION WITH NAMED PROFILE =====
session = boto3.Session(profile_name=AWS_PROFILE)
sts_client = session.client("sts")

# ===== ASSUME THE BEDROCK ROLE =====
assumed = sts_client.assume_role(
    RoleArn=BEDROCK_ROLE_ARN,
    RoleSessionName="local-bedrock-test"
)

creds = assumed["Credentials"]

# ===== CREATE BEDROCK RUNTIME CLIENT =====
br_client = boto3.client(
    "bedrock-runtime",
    region_name=REGION,
    aws_access_key_id=creds["AccessKeyId"],
    aws_secret_access_key=creds["SecretAccessKey"],
    aws_session_token=creds["SessionToken"],
)

# ===== INVOKE MODEL =====
response = br_client.invoke_model(
    modelId=MODEL_ID,
    body=json.dumps({
        "guardrailId": GUARDRAIL_ID,
        "guardrailVersion": GUARDRAIL_VERSION,
        "messages": [
            {"role": "user", "content": PROMPT_TEXT}
        ],
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 100
    }),
    contentType="application/json",
    accept="application/json"
)

# ===== PRINT OUTPUT =====
response_body = json.loads(response["body"].read())
output_text = response_body["content"][0]["text"]
print("🧠 Bedrock Response:", output_text)
