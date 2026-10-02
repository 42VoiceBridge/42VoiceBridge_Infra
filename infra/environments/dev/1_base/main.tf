# 1_base — VPC, 서브넷, 라우팅, 보안그룹
# 의존성 없음 (최상위 레이어)

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
    key          = "dev/1_base/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}
