import json
import os
import re
import uuid
from datetime import datetime, timezone

import boto3

s3 = boto3.client("s3")
ddb = boto3.resource("dynamodb")
table = ddb.Table(os.environ["TABLE_NAME"])
BUCKET = os.environ["DATA_BUCKET"]
MAX_BYTES = int(os.environ.get("MAX_UPLOAD_BYTES", "104857600"))
URL_TTL = int(os.environ.get("URL_EXPIRATION_SECONDS", "300"))
DEFAULT_LANGUAGE = os.environ.get("DEFAULT_LANGUAGE_CODE", "es-US")
ALLOWED_EXTENSIONS = {"mp3", "mp4", "wav", "flac", "ogg", "amr", "webm", "m4a"}
ALLOWED_LANGUAGES = {"es-US", "es-ES", "es-MX", "en-US"}


def response(status, payload):
    return {"statusCode": status, "headers": {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"}, "body": json.dumps(payload, ensure_ascii=False)}


def lambda_handler(event, context):
    uid = "shared"
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return response(400, {"error": "El cuerpo de la solicitud no es JSON válido."})

    filename = os.path.basename(str(body.get("filename", "audio"))).strip()
    if not filename or len(filename) > 180:
        return response(400, {"error": "El nombre del archivo es obligatorio y debe tener máximo 180 caracteres."})
    ext_match = re.search(r"\.([A-Za-z0-9]+)$", filename)
    extension = ext_match.group(1).lower() if ext_match else ""
    if extension not in ALLOWED_EXTENSIONS:
        return response(400, {"error": "Formato no admitido. Usa mp3, mp4, wav, flac, ogg, amr, webm o m4a."})

    try:
        size_bytes = int(body.get("size_bytes", 0))
    except (TypeError, ValueError):
        return response(400, {"error": "size_bytes debe ser un número entero."})
    if size_bytes <= 0 or size_bytes > MAX_BYTES:
        return response(400, {"error": f"El archivo debe pesar entre 1 byte y {MAX_BYTES // (1024 * 1024)} MB."})

    language = body.get("language_code") or DEFAULT_LANGUAGE
    if language not in ALLOWED_LANGUAGES:
        return response(400, {"error": "Idioma no permitido por este ejemplo. Usa es-US, es-ES, es-MX o en-US."})

    content_type = str(body.get("content_type") or "application/octet-stream")[:120]
    if not re.fullmatch(r"[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+", content_type):
        content_type = "application/octet-stream"
    file_id = uuid.uuid4().hex
    key = f"uploads/{uid}/{file_id}.{extension}"
    transcript_key = f"transcripts/{uid}/{file_id}.json"
    now = datetime.now(timezone.utc).isoformat()
    item = {
        "user_id": uid,
        "item_id": f"FILE#{file_id}",
        "file_id": file_id,
        "job_id": f"{uid}-{file_id}",
        "filename": filename,
        "content_type": content_type,
        "size_bytes": size_bytes,
        "language_code": language,
        "s3_key": key,
        "transcript_key": transcript_key,
        "status": "UPLOADING",
        "created_at": now,
        "updated_at": now,
    }
    table.put_item(Item=item, ConditionExpression="attribute_not_exists(user_id) AND attribute_not_exists(item_id)")
    presigned = s3.generate_presigned_post(
        Bucket=BUCKET,
        Key=key,
        Fields={"Content-Type": content_type},
        Conditions=[
            {"Content-Type": content_type},
            ["content-length-range", 1, MAX_BYTES],
        ],
        ExpiresIn=URL_TTL,
    )
    return response(201, {
        "file_id": file_id,
        "filename": filename,
        "status": "UPLOADING",
        "upload_url": presigned["url"],
        "upload_fields": presigned["fields"],
        "expires_in_seconds": URL_TTL,
    })
