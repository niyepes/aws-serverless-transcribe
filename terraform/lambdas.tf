locals {
  lambda_defs = {
    create_upload = {
      timeout = 30, memory = 256
      environment = {
        DATA_BUCKET            = aws_s3_bucket.data.bucket
        TABLE_NAME             = aws_dynamodb_table.items.name
        MAX_UPLOAD_BYTES       = tostring(var.max_upload_mb * 1024 * 1024)
        URL_EXPIRATION_SECONDS = "300"
        DEFAULT_LANGUAGE_CODE  = var.transcribe_language_code
      }
      permissions = ["ddb_put", "s3_put_upload"]
    }
    start_transcribe = {
      timeout = 60, memory = 256
      environment = {
        DATA_BUCKET           = aws_s3_bucket.data.bucket
        TABLE_NAME            = aws_dynamodb_table.items.name
        DEFAULT_LANGUAGE_CODE = var.transcribe_language_code
      }
      permissions = ["ddb_get", "ddb_update", "s3_get_uploads", "s3_put_transcripts", "transcribe_start"]
    }
    transcribe_complete = {
      timeout = 30, memory = 256
      environment = {
        TABLE_NAME = aws_dynamodb_table.items.name
      }
      permissions = ["ddb_get", "ddb_update"]
    }
    list_items = {
      timeout = 30, memory = 256
      environment = {
        TABLE_NAME = aws_dynamodb_table.items.name
      }
      permissions = ["ddb_query", "ddb_update", "transcribe_get"]
    }
    get_transcript = {
      timeout = 30, memory = 256
      environment = {
        DATA_BUCKET = aws_s3_bucket.data.bucket
        TABLE_NAME  = aws_dynamodb_table.items.name
      }
      permissions = ["ddb_get", "s3_get_transcripts"]
    }
    create_summary = {
      timeout = 30, memory = 256
      environment = {
        TABLE_NAME        = aws_dynamodb_table.items.name
        SUMMARY_QUEUE_URL = aws_sqs_queue.summary_jobs.url
        MAX_TRANSCRIPTS   = "50"
      }
      permissions = ["ddb_query", "ddb_put", "ddb_update", "sqs_send"]
    }
    get_summary = {
      timeout = 30, memory = 256
      environment = {
        DATA_BUCKET            = aws_s3_bucket.data.bucket
        TABLE_NAME             = aws_dynamodb_table.items.name
        URL_EXPIRATION_SECONDS = "300"
      }
      permissions = ["ddb_get", "s3_get_summaries"]
    }
    summary_worker = {
      timeout = 900, memory = 1024
      environment = {
        DATA_BUCKET      = aws_s3_bucket.data.bucket
        TABLE_NAME       = aws_dynamodb_table.items.name
        BEDROCK_MODEL_ID = var.bedrock_model_id
        CHUNK_CHARS      = "10000"
        MAX_CHUNKS       = "10"
      }
      permissions = ["ddb_get", "ddb_update", "s3_get_transcripts", "s3_put_summaries", "bedrock_invoke", "sqs_consume"]
    }
  }

  permission_statements = {
    ddb_get = {
      Effect = "Allow", Action = ["dynamodb:GetItem"], Resource = aws_dynamodb_table.items.arn
    }
    ddb_put = {
      Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.items.arn
    }
    ddb_update = {
      Effect = "Allow", Action = ["dynamodb:UpdateItem"], Resource = aws_dynamodb_table.items.arn
    }
    ddb_query = {
      Effect = "Allow", Action = ["dynamodb:Query"], Resource = [aws_dynamodb_table.items.arn, "${aws_dynamodb_table.items.arn}/index/*"]
    }
    s3_put_upload = {
      Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.data.arn}/uploads/*"
    }
    s3_get_uploads = {
      Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.data.arn}/uploads/*"
    }
    s3_put_transcripts = {
      Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.data.arn}/transcripts/*"
    }
    s3_get_transcripts = {
      Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.data.arn}/transcripts/*"
    }
    s3_put_summaries = {
      Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.data.arn}/summaries/*"
    }
    s3_get_summaries = {
      Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.data.arn}/summaries/*"
    }
    transcribe_start = {
      Effect = "Allow", Action = ["transcribe:StartTranscriptionJob"], Resource = "*"
    }
    transcribe_get = {
      Effect = "Allow", Action = ["transcribe:GetTranscriptionJob"], Resource = "*"
    }
    sqs_send = {
      Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.summary_jobs.arn
    }
    bedrock_invoke = {
      Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_model_id}"
    }
    sqs_consume = {
      Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = aws_sqs_queue.summary_jobs.arn
    }
  }
}

data "archive_file" "lambda" {
  for_each    = local.lambda_defs
  type        = "zip"
  source_dir  = "${path.module}/../src/lambdas/${each.key}"
  output_path = "${path.module}/build/${each.key}.zip"
}

resource "aws_iam_role" "lambda" {
  for_each = local.lambda_defs
  name     = "${var.project_name}-${each.key}-${random_id.suffix.hex}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic_logs" {
  for_each   = local.lambda_defs
  role       = aws_iam_role.lambda[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "least_privilege" {
  for_each = local.lambda_defs
  name     = "${var.project_name}-${each.key}-permissions"
  role     = aws_iam_role.lambda[each.key].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [for permission in each.value.permissions : local.permission_statements[permission]]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = local.lambda_defs
  name              = "/aws/lambda/${var.project_name}-${each.key}"
  retention_in_days = 14
}

resource "aws_lambda_function" "lambda" {
  for_each         = local.lambda_defs
  function_name    = "${var.project_name}-${each.key}"
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.lambda[each.key].output_path
  source_code_hash = data.archive_file.lambda[each.key].output_base64sha256
  timeout          = each.value.timeout
  memory_size      = each.value.memory
  environment { variables = each.value.environment }

  depends_on = [
    aws_iam_role_policy_attachment.basic_logs,
    aws_iam_role_policy.least_privilege,
    aws_cloudwatch_log_group.lambda
  ]
}

resource "aws_s3_bucket_notification" "uploads" {
  bucket = aws_s3_bucket.data.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.lambda["start_transcribe"].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "uploads/"
  }
  depends_on = [aws_lambda_permission.s3_start_transcribe]
}

resource "aws_lambda_permission" "s3_start_transcribe" {
  statement_id   = "AllowS3InvokeStartTranscribe"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.lambda["start_transcribe"].function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.data.arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_cloudwatch_event_rule" "transcribe_state" {
  name        = "${var.project_name}-transcribe-state-${random_id.suffix.hex}"
  description = "Actualiza DynamoDB cuando Amazon Transcribe termina un trabajo."
  event_pattern = jsonencode({
    source        = ["aws.transcribe"]
    "detail-type" = ["Transcribe Job State Change"]
    detail        = { TranscriptionJobStatus = ["COMPLETED", "FAILED"] }
  })
}

resource "aws_cloudwatch_event_target" "transcribe_complete" {
  rule       = aws_cloudwatch_event_rule.transcribe_state.name
  target_id  = "transcribe-complete-lambda"
  arn        = aws_lambda_function.lambda["transcribe_complete"].arn
  depends_on = [aws_lambda_permission.eventbridge_transcribe]
}

resource "aws_lambda_permission" "eventbridge_transcribe" {
  statement_id  = "AllowEventBridgeInvokeTranscribeComplete"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda["transcribe_complete"].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.transcribe_state.arn
}

resource "aws_lambda_event_source_mapping" "summary_worker" {
  event_source_arn                   = aws_sqs_queue.summary_jobs.arn
  function_name                      = aws_lambda_function.lambda["summary_worker"].arn
  batch_size                         = 1
  maximum_batching_window_in_seconds = 0
  enabled                            = true
}
