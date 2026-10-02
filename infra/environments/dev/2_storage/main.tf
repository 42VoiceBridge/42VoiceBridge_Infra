# 2_storage — RDS, ElastiCache, S3
# 의존성: 1_base (프라이빗 서브넷 ID, rds-sg/redis-sg ID)

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket       = "42voicebridge-tfstate"
    key          = "dev/2_storage/terraform.tfstate"
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
