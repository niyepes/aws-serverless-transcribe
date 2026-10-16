import json
import os

import boto3

s3 = boto3.client("s3")
ddb = boto3.resource("dynamodb")
table = ddb.Table(os.environ["TABLE_NAME"])
BUCKET = os.environ["DATA_BUCKET"]


def response(status, payload):
    return {"statusCode": status, "headers": {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"}, "body": json.dumps(payload, ensure_ascii=False)}


def lambda_handler(event, context):
    uid = "shared"
    file_id = (event.get("pathParameters") or {}).get("id", "")
    if not file_id or len(file_id) > 80:
        return response(400, {"error": "Identificador de archivo inválido."})
    item = table.get_item(Key={"user_id": uid, "item_id": f"FILE#{file_id}"}).get("Item")
    if not item:
        return response(404, {"error": "Archivo no encontrado."})
    if item.get("status") != "COMPLETED":
        return response(409, {"error": "La transcripción todavía no está disponible.", "status": item.get("status")})
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=item["transcript_key"])
        data = json.loads(obj["Body"].read().decode("utf-8"))
        transcript = data.get("results", {}).get("transcripts", [{}])[0].get("transcript", "")
    except Exception as exc:
        print(f"Cannot read transcript for {file_id}: {exc}")
        return response(502, {"error": "No se pudo recuperar el contenido de la transcripción."})
    return response(200, {"id": file_id, "filename": item.get("filename", "archivo"), "transcript": transcript, "created_at": item.get("created_at", "")})
