output "frontend_url" {
  description = "URL pública HTTPS de la aplicación. La UI está en un bucket S3 privado accesible solo por CloudFront."
  value       = "https://${aws_cloudfront_distribution.site.domain_name}/"
}

output "cloudfront_distribution_id" {
  description = "ID de distribución CloudFront; útil para invalidaciones manuales."
  value       = aws_cloudfront_distribution.site.id
}

output "api_endpoint" {
  description = "Endpoint base de API Gateway HTTP API. Las rutas no requieren autenticación."
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "data_bucket_name" {
  description = "Bucket privado que contiene audios, salidas de Transcribe y resúmenes."
  value       = aws_s3_bucket.data.bucket
}

output "dynamodb_table_name" {
  description = "Tabla de metadatos de archivos y resúmenes."
  value       = aws_dynamodb_table.items.name
}

output "bedrock_model_id" {
  description = "ID de modelo de Bedrock configurado."
  value       = var.bedrock_model_id
}

output "aws_region" {
  description = "Región de AWS usada por el despliegue."
  value       = var.aws_region
}
