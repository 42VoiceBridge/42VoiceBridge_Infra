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

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed to SSH (port 22) into the app server. Do NOT use 0.0.0.0/0 — restrict to your own IP (e.g. 1.2.3.4/32)."
  type        = string
}
