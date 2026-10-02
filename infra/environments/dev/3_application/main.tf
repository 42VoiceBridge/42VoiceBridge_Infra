# 3_application — EC2, Elastic IP, IAM
# 의존성: 1_base (퍼블릭 서브넷 ID, app-sg ID), 2_storage (S3 버킷 ARN, RDS/Redis 엔드포인트)

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "42voicebridge-tfstate"
    key          = "dev/3_application/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = "42voicebridge-tfstate"
    key    = "dev/1_base/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

data "terraform_remote_state" "storage" {
  backend = "s3"
  config = {
    bucket = "42voicebridge-tfstate"
    key    = "dev/2_storage/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
