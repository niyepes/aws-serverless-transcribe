variable "aws_region" {
  description = "Región para API Gateway, Lambda, S3, Transcribe y Bedrock. CloudFront es global."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo de nombres de recursos. Solo minúsculas, números y guiones."
  type        = string
  default     = "audio-intelligence"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.project_name))
    error_message = "project_name debe tener entre 3 y 24 caracteres, empezar por una letra, terminar en letra o número y usar minúsculas, números o guiones."
  }
}

variable "environment" {
  description = "Etiqueta de entorno."
  type        = string
  default     = "demo"
}

variable "bedrock_model_id" {
  description = "ID de un modelo fundacional de Bedrock disponible en aws_region; se usa con Converse API."
  type        = string
  default     = "amazon.nova-lite-v1:0"
}

variable "transcribe_language_code" {
  description = "Código de idioma para Amazon Transcribe. Verifique que esté disponible en aws_region."
  type        = string
  default     = "es-US"
}

variable "max_upload_mb" {
  description = "Tamaño máximo de audio por archivo en MB, validado por la interfaz y la API de creación de URL."
  type        = number
  default     = 100
  validation {
    condition     = var.max_upload_mb >= 1 && var.max_upload_mb <= 500 && floor(var.max_upload_mb) == var.max_upload_mb
    error_message = "max_upload_mb debe ser un entero entre 1 y 500."
  }
}
