variable "project_name" {
  description = "Project name prefix used for tagging and resource naming"
  type        = string
  default     = "voicebridge"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-northeast-2"
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type"
  type        = string
  default     = "cache.m5.large"
}

variable "db_name" {
  description = "Initial database name created on the RDS instance"
  type        = string
  default     = "voicebridge"
}

variable "db_username" {
  description = "Master username for the RDS instance (password is auto-managed by Secrets Manager)"
  type        = string
  default     = "voicebridge_admin"
}
