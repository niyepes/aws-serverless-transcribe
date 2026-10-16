import os
from datetime import datetime, timezone

import boto3

ddb = boto3.resource("dynamodb")
table = ddb.Table(os.environ["TABLE_NAME"])


def lambda_handler(event, context):
    detail = event.get("detail", {})
    job_name = detail.get("TranscriptionJobName", "")
    status = detail.get("TranscriptionJobStatus", "")
    if len(job_name) < 69 or job_name[36:37] != "-":
        print(f"Unexpected transcription job name: {job_name}")
        return {"ignored": True}

    uid, file_id = job_name[:36], job_name[37:]
    key = {"user_id": uid, "item_id": f"FILE#{file_id}"}
    existing = table.get_item(Key=key).get("Item")
    if not existing:
        print(f"No DynamoDB record for job {job_name}")
        return {"ignored": True}

    now = datetime.now(timezone.utc).isoformat()
    if status == "COMPLETED":
        table.update_item(
            Key=key,
            UpdateExpression="SET #s = :s, updated_at = :u, completed_at = :c REMOVE failure_reason",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "COMPLETED", ":u": now, ":c": now},
        )
    elif status == "FAILED":
        reason = str(detail.get("FailureReason", "Amazon Transcribe indicó que el trabajo falló."))[:500]
        table.update_item(
            Key=key,
            UpdateExpression="SET #s = :s, updated_at = :u, failure_reason = :f",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "FAILED", ":u": now, ":f": reason},
        )
    return {"job_id": job_name, "status": status}
