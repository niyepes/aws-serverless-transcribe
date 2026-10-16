import json
import os
import re

import boto3

s3 = boto3.client("s3")
ddb = boto3.resource("dynamodb")
table = ddb.Table(os.environ["TABLE_NAME"])
BUCKET = os.environ["DATA_BUCKET"]
URL_TTL = int(os.environ.get("URL_EXPIRATION_SECONDS", "300"))


def response(status, payload):
    return {"statusCode": status, "headers": {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"}, "body": json.dumps(payload, ensure_ascii=False)}


def lambda_handler(event, context):
    uid = "shared"
    summary_id = (event.get("pathParameters") or {}).get("id", "")
    if not re.fullmatch(r"[0-9a-f]{32}", summary_id):
        return response(400, {"error": "Identificador de resumen inválido."})
    item = table.get_item(Key={"user_id": uid, "item_id": f"SUMMARY#{summary_id}"}).get("Item")
    if not item:
        return response(404, {"error": "Resumen no encontrado."})
    payload = {
        "id": summary_id,
        "status": item.get("status", "UNKNOWN"),
        "filename": item.get("filename", "resumen_consolidado.md"),
        "file_count": int(item.get("file_count", 0)),
        "created_at": item.get("created_at", ""),
        "failure_reason": item.get("failure_reason", ""),
    }
    if item.get("status") == "COMPLETED" and item.get("summary_key"):
        payload["download_url"] = s3.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": BUCKET,
                "Key": item["summary_key"],
                "ResponseContentType": "text/markdown; charset=utf-8",
                "ResponseContentDisposition": f'attachment; filename="{item.get("filename", "resumen_consolidado.md")}"',
            },
            ExpiresIn=URL_TTL,
        )
        payload["download_url_expires_in_seconds"] = URL_TTL
    return response(200, payload)
