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

variable "instance_type" {
  description = "EC2 instance type for the app server"
  type        = string
  default     = "m5.large"
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.r5.large"
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type"
  type        = string
  default     = "cache.m5.large"
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed to SSH (port 22) into the app server. Do NOT use 0.0.0.0/0 — restrict to your own IP (e.g. 1.2.3.4/32)."
  type        = string
}

variable "ssh_key_name" {
  description = "Name of the existing EC2 key pair (create in AWS Console) to use for SSH access"
  type        = string
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
