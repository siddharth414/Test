import json
import boto3
import os
import uuid
import time
from bedrockv2 import BedrockRuntime
from botocore.exceptions import ClientError

# ENV VARIABLES
BEDROCK_ROLE_ARN = os.getenv("BEDROCK_ROLE_ARN")
BEDROCK_GUARDRAIL_ID = os.getenv("BEDROCK_GUARDRAIL_ID")
BEDROCK_GUARDRAIL_VERSION = os.getenv("BEDROCK_GUARDRAIL_VERSION")
OUTPUT_BUCKET = os.getenv("OUTPUT_BUCKET")
OUTPUT_FOLDER = os.getenv("OUTPUT_FOLDER", "classified")
INPUT_BUCKET = os.getenv("INPUT_BUCKET")
INPUT_PREFIX = os.getenv("INPUT_PREFIX", "")
MODEL_ID = os.getenv("MODEL_ID")

# Assume role to get temporary credentials
def assume_bedrock_role():
    sts = boto3.client("sts")
    resp = sts.assume_role(
        RoleArn=BEDROCK_ROLE_ARN,
        RoleSessionName="BedrockLambdaSession"
    )
    creds = resp["Credentials"]
    return {
        "aws_access_key_id": creds["AccessKeyId"],
        "aws_secret_access_key": creds["SecretAccessKey"],
        "aws_session_token": creds["SessionToken"]
    }

# Invoke Bedrock model
def invoke_model(model_id, text):
    creds = assume_bedrock_role()
    br = BedrockRuntime(region_name="us-east-1", **creds)

    system = {"text": "You are a helpful AI assistant."}
    prompt = f"""
You are a classification model for a bank's helpline call summaries.
Classify the following summary as either High Priority or Low Priority using these rules:

1. High Priority if:
  - The amount involved is greater than $5000 and the issue affects the caller financially.
  - There is any suspicious or unauthorized transaction, regardless of the amount.
  - The description indicates an unusual or abnormal situation (e.g., fraud, unexpected approval, etc.).

2. Low Priority otherwise.

Return only one word: High or Low.

Summary:
"{text}"
"""
    messages = [{"role": "user", "content": prompt}]

    resp = br.converse(
        modelId=model_id,
        system=system,
        messages=messages,
        inferenceConfig={
            "guardrailIdentifier": BEDROCK_GUARDRAIL_ID,
            "guardrailVersion": BEDROCK_GUARDRAIL_VERSION,
            "trace": "enabled"
        }
    )

    return resp["output"]["messages"][0]["content"]

# Process each record
def process_record(record):
    body = json.loads(record["body"])
    summary = body.get("summary")
    record_id = body.get("record_id", str(uuid.uuid4()))

    classification = invoke_model(MODEL_ID, summary)
    result = {
        "record_id": record_id,
        "summary": summary,
        "classification": classification
    }

    return result

# Lambda handler
def lambda_handler(event, context):
    s3 = boto3.client("s3")
    response = s3.list_objects_v2(Bucket=INPUT_BUCKET, Prefix=INPUT_PREFIX)
    all_results = []

    for obj in response.get("Contents", []):
        key = obj["Key"]
        if not key.endswith(".json"):
            continue

        try:
            s3_obj = s3.get_object(Bucket=INPUT_BUCKET, Key=key)
            body = s3_obj["Body"].read().decode("utf-8")
            record = json.loads(body)
            result = process_record({"body": json.dumps(record)})
            all_results.append(result)
        except Exception as e:
            all_results.append({
                "record_id": record.get("record_id", key),
                "error": str(e)
            })

    # Write one batch output file
    timestamp = int(time.time())
    output_key = f"{OUTPUT_FOLDER}/batch_{timestamp}.json"
    s3.put_object(
        Bucket=OUTPUT_BUCKET,
        Key=output_key,
        Body=json.dumps(all_results)  # compact version (no indent)
    )

    return {
        "statusCode": 200,
        "output_file": output_key,
        "records_processed": len(all_results)
    }
