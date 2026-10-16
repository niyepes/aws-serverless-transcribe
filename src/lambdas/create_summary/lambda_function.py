import json
import os
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key

sqs = boto3.client("sqs")
ddb = boto3.resource("dynamodb")
table = ddb.Table(os.environ["TABLE_NAME"])
QUEUE_URL = os.environ["SUMMARY_QUEUE_URL"]
MAX_TRANSCRIPTS = int(os.environ.get("MAX_TRANSCRIPTS", "50"))


def response(status, payload):
    return {"statusCode": status, "headers": {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"}, "body": json.dumps(payload, ensure_ascii=False)}


def lambda_handler(event, context):
    uid = "shared"

    items, start_key = [], None
    while True:
        args = {"KeyConditionExpression": Key("user_id").eq(uid) & Key("item_id").begins_with("FILE#"), "Limit": 100}
        if start_key:
            args["ExclusiveStartKey"] = start_key
        result = table.query(**args)
        items.extend(result.get("Items", []))
        start_key = result.get("LastEvaluatedKey")
        if not start_key or len(items) >= 501:
            break
    completed = [x for x in items if x.get("status") == "COMPLETED"]
    completed.sort(key=lambda x: x.get("created_at", ""))
    if not completed:
        return response(409, {"error": "No hay transcripciones completadas para resumir."})
    if len(completed) > MAX_TRANSCRIPTS:
        return response(413, {"error": f"Hay {len(completed)} transcripciones completadas. Este ejemplo admite un máximo de {MAX_TRANSCRIPTS} por resumen."})

    summary_id = uuid.uuid4().hex
    now = datetime.now(timezone.utc).isoformat()
    included = [x.get("file_id", x["item_id"].removeprefix("FILE#")) for x in completed]
    item = {
        "user_id": uid,
        "item_id": f"SUMMARY#{summary_id}",
        "summary_id": summary_id,
        "filename": f"resumen_consolidado_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}.md",
        "status": "QUEUED",
        "file_count": len(included),
        "included_file_ids": included,
        "created_at": now,
        "updated_at": now,
    }
    table.put_item(Item=item, ConditionExpression="attribute_not_exists(user_id) AND attribute_not_exists(item_id)")
    try:
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({"user_id": uid, "summary_id": summary_id, "file_ids": included}))
    except Exception as exc:
        table.update_item(
            Key={"user_id": uid, "item_id": f"SUMMARY#{summary_id}"},
            UpdateExpression="SET #s = :s, failure_reason = :f, updated_at = :u",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "FAILED", ":f": str(exc)[:500], ":u": datetime.now(timezone.utc).isoformat()},
        )
        return response(500, {"error": "No se pudo encolar la generación del resumen."})
    return response(202, {"id": summary_id, "status": "QUEUED", "file_count": len(included), "message": "Resumen encolado. Consulta el estado en la lista de resúmenes."})
