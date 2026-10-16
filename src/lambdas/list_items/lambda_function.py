import json
import os
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

transcribe = boto3.client("transcribe")
_ddb = boto3.resource("dynamodb")
table = _ddb.Table(os.environ["TABLE_NAME"])


def response(status, payload):
    return {"statusCode": status, "headers": {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"}, "body": json.dumps(payload, ensure_ascii=False)}


def refresh_transcription_status(uid, item):
    if item.get("status") != "TRANSCRIBING" or not item.get("job_id"):
        return item
    try:
        job = transcribe.get_transcription_job(TranscriptionJobName=item["job_id"]).get("TranscriptionJob", {})
        job_status = job.get("TranscriptionJobStatus")
        target_status = {"IN_PROGRESS": "TRANSCRIBING", "COMPLETED": "COMPLETED", "FAILED": "FAILED"}.get(job_status)
        if target_status and target_status != item.get("status"):
            now = datetime.now(timezone.utc).isoformat()
            if target_status == "FAILED":
                table.update_item(
                    Key={"user_id": uid, "item_id": item["item_id"]},
                    UpdateExpression="SET #s = :s, updated_at = :u, failure_reason = :f",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":s": target_status, ":u": now, ":f": str(job.get("FailureReason", "Amazon Transcribe indicó que el trabajo falló."))[:500]},
                )
                item["failure_reason"] = str(job.get("FailureReason", "Amazon Transcribe indicó que el trabajo falló."))[:500]
            else:
                table.update_item(
                    Key={"user_id": uid, "item_id": item["item_id"]},
                    UpdateExpression="SET #s = :s, updated_at = :u",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":s": target_status, ":u": now},
                )
            item["status"] = target_status
    except ClientError as exc:
        print(f"Could not reconcile Transcribe status for {item.get('job_id')}: {exc}")
    return item


def lambda_handler(event, context):
    uid = "shared"
    path = event.get("rawPath", "")
    prefix = "SUMMARY#" if path.rstrip("/").endswith("summaries") else "FILE#"
    items, start_key = [], None
    while True:
        args = {
            "KeyConditionExpression": Key("user_id").eq(uid) & Key("item_id").begins_with(prefix),
            "Limit": 100,
            "ScanIndexForward": False,
        }
        if start_key:
            args["ExclusiveStartKey"] = start_key
        result = table.query(**args)
        items.extend(result.get("Items", []))
        start_key = result.get("LastEvaluatedKey")
        if not start_key or len(items) >= 500:
            break
    if prefix == "FILE#":
        items = [refresh_transcription_status(uid, item) for item in items]
    items.sort(key=lambda item: item.get("created_at", ""), reverse=True)
    if prefix == "FILE#":
        output = [{
            "id": item.get("file_id", item.get("item_id", "").removeprefix("FILE#")),
            "filename": item.get("filename", "archivo"),
            "status": item.get("status", "UNKNOWN"),
            "language_code": item.get("language_code", ""),
            "size_bytes": int(item.get("size_bytes", 0)),
            "created_at": item.get("created_at", ""),
            "failure_reason": item.get("failure_reason", ""),
        } for item in items]
        return response(200, {"items": output})

    output = [{
        "id": item.get("summary_id", item.get("item_id", "").removeprefix("SUMMARY#")),
        "status": item.get("status", "UNKNOWN"),
        "filename": item.get("filename", "resumen_consolidado.md"),
        "file_count": int(item.get("file_count", 0)),
        "created_at": item.get("created_at", ""),
        "failure_reason": item.get("failure_reason", ""),
    } for item in items]
    return response(200, {"items": output})
