resource "aws_apigatewayv2_api" "http" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = [local.frontend_origin]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 3600
  }
}

locals {
  api_routes = {
    "POST /uploads"         = "create_upload"
    "GET /transcripts"      = "list_items"
    "GET /summaries"        = "list_items"
    "GET /transcripts/{id}" = "get_transcript"
    "POST /summaries"       = "create_summary"
    "GET /summaries/{id}"   = "get_summary"
  }
  api_lambda_names = toset(values(local.api_routes))
}

resource "aws_apigatewayv2_integration" "route" {
  for_each               = local.api_routes
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.lambda[each.value].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "route" {
  for_each           = local.api_routes
  api_id             = aws_apigatewayv2_api.http.id
  route_key          = each.key
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.route[each.key].id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
}

resource "aws_lambda_permission" "api_invoke" {
  for_each      = local.api_lambda_names
  statement_id  = "AllowHttpApiInvoke-${replace(each.key, "_", "-")}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project_name}-frontend-oac"
  description                       = "Permite a CloudFront leer el bucket privado del frontend."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  comment             = "${var.project_name} frontend"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2and3"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "private-s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id       = "private-s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled; avoids stale SPA config during demos.
  }

  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate { cloudfront_default_certificate = true }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontOACRead"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site.arn } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.frontend.arn, "${aws_s3_bucket.frontend.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

locals {
  frontend_assets = {
    "index.html" = {
      source       = "${path.module}/../frontend/index.html"
      content_type = "text/html; charset=utf-8"
    }
    "styles.css" = {
      source       = "${path.module}/../frontend/styles.css"
      content_type = "text/css; charset=utf-8"
    }
    "app.js" = {
      source       = "${path.module}/../frontend/app.js"
      content_type = "application/javascript; charset=utf-8"
    }
  }
  frontend_url = "${local.frontend_origin}/"
}

resource "aws_s3_object" "frontend_assets" {
  for_each      = local.frontend_assets
  bucket        = aws_s3_bucket.frontend.id
  key           = each.key
  source        = each.value.source
  etag          = filemd5(each.value.source)
  content_type  = each.value.content_type
  cache_control = "no-cache, no-store, must-revalidate"
  depends_on    = [aws_s3_bucket_ownership_controls.frontend]
}

resource "aws_s3_object" "runtime_config" {
  bucket        = aws_s3_bucket.frontend.id
  key           = "config.js"
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "no-cache, no-store, must-revalidate"
  content = templatefile("${path.module}/../frontend/config.js.tftpl", {
    aws_region   = var.aws_region
    api_base_url = aws_apigatewayv2_api.http.api_endpoint
  })
  depends_on = [aws_s3_bucket_ownership_controls.frontend]
}
