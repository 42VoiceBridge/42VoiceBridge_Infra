# 3_application — EC2, Elastic IP, IAM
# 의존성: 1_base (퍼블릭 서브넷 ID, app-sg ID), 2_storage (S3 버킷 ARN, RDS/Redis 엔드포인트)

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "base" {
  backend = "local"
  config = {
    path = "../1_base/terraform.tfstate"
  }
}

data "terraform_remote_state" "storage" {
  backend = "local"
  config = {
    path = "../2_storage/terraform.tfstate"
  }
}
