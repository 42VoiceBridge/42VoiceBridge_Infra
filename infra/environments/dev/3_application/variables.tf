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

# 인스턴스 사양은 모두 "초기 시험 사양"이다. 배포 후 CloudWatch/SSM 실측으로 확정한다
# (docs/OPERATIONS-SIZING.md). AI 메모리 실측은 추론 3건 기준(1.67 GiB)뿐이라 학습 중 값은 없다.
variable "be_instance_type" {
  description = "EC2 instance type for the BE instance (initial trial size)"
  type        = string
  default     = "t3.small"
}

variable "ai_instance_type" {
  description = "EC2 instance type for the AI instance. Initial trial size: 4 vCPU for CPU training headroom; confirm with measurements"
  type        = string
  default     = "t3.small"
}

variable "fe_instance_type" {
  description = "EC2 instance type for the FE instance (nginx static site + Caddy edge)"
  type        = string
  default     = "t3.small"
}

variable "be_root_volume_size_gb" {
  description = "Root EBS volume size (GiB) for BE: OS + BE image (JRE + ffmpeg)"
  type        = number
  default     = 30
}

variable "ai_root_volume_size_gb" {
  description = "Root EBS volume size (GiB) for AI: OS + AI image (1.61 GB, PyTorch CPU)"
  type        = number
  default     = 40
}

variable "fe_root_volume_size_gb" {
  description = "Root EBS volume size (GiB) for FE: OS + FE image + Caddy image"
  type        = number
  default     = 30
}

variable "data_volume_size_gb" {
  description = "Persistent data EBS volume size (GiB) mounted at /data on the AI instance (HF cache, adapters, enrollment data, jobs, prompt pool)"
  type        = number
  default     = 20
}

variable "data_snapshot_id" {
  description = "Restore the AI data volume from this snapshot (snap-...) when the volume is (re)created. Empty = create a blank volume. Changing it on an existing volume forces replacement, which prevent_destroy blocks on purpose (see docs/DATA-PROTECTION.md)"
  type        = string
  default     = ""

  validation {
    condition     = var.data_snapshot_id == "" || can(regex("^snap-[0-9a-f]{8,17}$", var.data_snapshot_id))
    error_message = "data_snapshot_id must be empty or look like snap-0123456789abcdef0."
  }
}

variable "data_snapshot_retention" {
  description = "Number of daily DLM snapshots of the AI data volume to keep"
  type        = number
  default     = 7
}

# 고정 사설 IP: 인스턴스를 교체해도 BE→AI, FE→BE 주소가 바뀌지 않게 한다.
# 퍼블릭 서브넷 10.0.1.0/24 안이어야 하고 .0~.3(AWS 예약)과 .255는 쓸 수 없다.
variable "be_private_ip" {
  description = "Fixed private IP of the BE instance (FE proxies /api to http://<ip>:8080)"
  type        = string
  default     = "10.0.1.10"

  validation {
    condition     = can(regex("^10\\.0\\.1\\.([4-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$", var.be_private_ip))
    error_message = "be_private_ip must be 10.0.1.4 - 10.0.1.254 (inside the public subnet, outside AWS reserved addresses)."
  }
}

variable "ai_private_ip" {
  description = "Fixed private IP of the AI instance (BE calls http://<ip>:8000; register it as AI_SERVER_BASE_URL)"
  type        = string
  default     = "10.0.1.20"

  validation {
    condition     = can(regex("^10\\.0\\.1\\.([4-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$", var.ai_private_ip)) && var.ai_private_ip != var.be_private_ip
    error_message = "ai_private_ip must be 10.0.1.4 - 10.0.1.254 and differ from be_private_ip."
  }
}

variable "fe_private_ip" {
  description = "Fixed private IP of the FE instance"
  type        = string
  default     = "10.0.1.30"

  validation {
    condition     = can(regex("^10\\.0\\.1\\.([4-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$", var.fe_private_ip)) && var.fe_private_ip != var.be_private_ip && var.fe_private_ip != var.ai_private_ip
    error_message = "fe_private_ip must be 10.0.1.4 - 10.0.1.254 and differ from the BE and AI addresses."
  }
}

variable "fe_domain" {
  description = "Public hostname for the FE (HTTPS). Empty = use the Elastic IP's public DNS name (ec2-<ip>.<region>.compute.amazonaws.com), which needs no domain but changes if the EIP is recreated. When you own a domain, point an A record at the EIP and set it here"
  type        = string
  default     = ""

  validation {
    condition     = var.fe_domain == "" || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.fe_domain))
    error_message = "fe_domain must be empty or a lowercase DNS name such as app.example.com."
  }
}

variable "ssh_key_name" {
  description = "Name of the existing EC2 key pair (create in AWS Console) used for SSH on the BE instance only. AI and FE are reached through SSM"
  type        = string
}

variable "app_secret_name" {
  description = "Name of the manually created Secrets Manager secret for backend runtime values (JWT, NCP keys, AI_SERVER_BASE_URL). Read by the BE role only"
  type        = string
  default     = "voicebridge/dev/app"
}

variable "ghcr_secret_name" {
  description = "Name of the Secrets Manager secret holding GHCR_USERNAME and GHCR_READ_TOKEN (classic PAT with read:packages). Read by all three roles"
  type        = string
  default     = "voicebridge/dev/ghcr"
}
