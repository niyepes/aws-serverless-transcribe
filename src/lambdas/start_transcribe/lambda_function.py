import os
import urllib.parse
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")
transcribe = boto3.client("transcribe")
ddb = boto3.resource("dynamodb")
table = ddb.Table(os.environ["TABLE_NAME"])
BUCKET = os.environ["DATA_BUCKET"]
DEFAULT_LANGUAGE = os.environ.get("DEFAULT_LANGUAGE_CODE", "es-US")
FORMATS = {"mp3", "mp4", "wav", "flac", "ogg", "amr", "webm", "m4a"}


def set_status(uid, file_id, status, **attrs):
    names = {"#s": "status", "#u": "updated_at"}
    values = {":s": status, ":u": datetime.now(timezone.utc).isoformat()}
    assignments = ["#s = :s", "#u = :u"]
    for index, (key, value) in enumerate(attrs.items()):
        nk, vk = f"#a{index}", f":a{index}"
        names[nk] = key
        values[vk] = value
        assignments.append(f"{nk} = {vk}")
    table.update_item(
        Key={"user_id": uid, "item_id": f"FILE#{file_id}"},
        UpdateExpression="SET " + ", ".join(assignments),
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )


def lambda_handler(event, context):
    for record in event.get("Records", []):
        key = urllib.parse.unquote_plus(record.get("s3", {}).get("object", {}).get("key", ""))
        parts = key.split("/")
        if len(parts) != 3 or parts[0] != "uploads":
            continue
        uid, leaf = parts[1], parts[2]
        file_id, dot, extension = leaf.rpartition(".")
        if not dot or extension.lower() not in FORMATS:
            continue

        result = table.get_item(Key={"user_id": uid, "item_id": f"FILE#{file_id}"})
        item = result.get("Item")
        if not item:
            continue
        if item.get("status") in {"TRANSCRIBING", "COMPLETED", "FAILED"}:
            continue

        try:
            transcribe.start_transcription_job(
                TranscriptionJobName=item["job_id"],
                LanguageCode=item.get("language_code", DEFAULT_LANGUAGE),
                MediaFormat=extension.lower(),
                Media={"MediaFileUri": f"s3://{BUCKET}/{key}"},
                OutputBucketName=BUCKET,
                OutputKey=item["transcript_key"],
            )
            set_status(uid, file_id, "TRANSCRIBING")
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code == "ConflictException":
                # S3 can deliver the same event more than once. Do not regress status.
                continue
            set_status(uid, file_id, "FAILED", failure_reason=str(exc)[:500])
            raise
    return {"processed": len(event.get("Records", []))}
