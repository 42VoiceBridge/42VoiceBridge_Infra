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

variable "ssh_key_name" {
  description = "Name of the existing EC2 key pair (create in AWS Console) to use for SSH access"
  type        = string
}

variable "app_secret_name" {
  description = "Name of the manually created Secrets Manager secret for backend runtime values"
  type        = string
  default     = "voicebridge/dev/app"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size (GiB). Holds the OS and Docker images (BE + AI); 40 leaves room for the PyTorch-based AI image"
  type        = number
  default     = 40
}

variable "data_volume_size_gb" {
  description = "Persistent data EBS volume size (GiB) mounted at /data (HF model cache, personalized adapters, prompt pool)"
  type        = number
  default     = 20
}
