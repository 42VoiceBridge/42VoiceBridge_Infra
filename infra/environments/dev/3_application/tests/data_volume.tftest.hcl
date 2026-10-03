# AWS 자격 증명 없이 실행되는 오프라인 테스트(mock 프로바이더).
# 실행: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_subnet" {
    defaults = {
      availability_zone = "ap-northeast-2a"
    }
  }
  mock_resource "aws_ebs_volume" {
    defaults = {
      id = "vol-0abc123def4567890"
    }
  }
}

override_data {
  target = data.terraform_remote_state.base
  values = {
    outputs = {
      public_subnet_id = "subnet-0123456789abcdef0"
      app_sg_id        = "sg-0123456789abcdef0"
    }
  }
}

override_data {
  target = data.terraform_remote_state.storage
  values = {
    outputs = {
      rds_endpoint   = "rds.example:3306"
      redis_endpoint = "redis.example"
      s3_bucket_name = "voicebridge-recordings-test"
      s3_bucket_arn  = "arn:aws:s3:::voicebridge-recordings-test"
      rds_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds-test"
    }
  }
}

variables {
  ssh_key_name = "test-key"
}

run "기본값은_root_40GB_데이터_20GB" {
  command = plan

  assert {
    condition     = aws_instance.app.root_block_device[0].volume_size == 40
    error_message = "root 볼륨은 40GiB여야 한다."
  }
  assert {
    condition     = aws_ebs_volume.data.size == 20 && aws_ebs_volume.data.type == "gp3"
    error_message = "데이터 볼륨은 gp3 20GiB여야 한다."
  }
  assert {
    condition     = aws_ebs_volume.data.encrypted
    error_message = "데이터 볼륨은 암호화돼야 한다."
  }
}

run "데이터_볼륨은_서브넷_AZ에_생성된다" {
  command = plan

  assert {
    condition     = aws_ebs_volume.data.availability_zone == "ap-northeast-2a"
    error_message = "볼륨 AZ는 앱 서브넷의 AZ여야 한다(인스턴스 속성 참조 시 순환)."
  }
}

run "attachment는_인스턴스를_정지한_뒤_분리한다" {
  command = plan

  assert {
    condition     = aws_volume_attachment.data.device_name == "/dev/sdf" && aws_volume_attachment.data.stop_instance_before_detaching
    error_message = "분리 전 인스턴스 정지 옵션이 필요하다."
  }
}

run "user_data가_볼륨ID_기반_장치경로를_사용한다" {
  # 새 볼륨 ID는 plan 시점에 미확정이라 user_data를 평가하려면 apply(mock)가 필요하다.
  command = apply

  assert {
    condition     = strcontains(aws_instance.app.user_data, "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0abc123def4567890")
    error_message = "장치 경로는 하이픈 없는 볼륨 ID 기반 by-id 경로여야 한다."
  }
  assert {
    condition     = strcontains(aws_instance.app.user_data, "blkid -p") && strcontains(aws_instance.app.user_data, "refusing to format")
    error_message = "기존 시그니처가 있으면 포맷하지 않는 보호 로직이 있어야 한다."
  }
  assert {
    condition     = strcontains(aws_instance.app.user_data, "UUID=$uuid") && strcontains(aws_instance.app.user_data, "nofail")
    error_message = "fstab은 UUID와 nofail로 등록해야 한다."
  }
  assert {
    condition     = strcontains(aws_instance.app.user_data, "amazon-ssm-agent")
    error_message = "기존 SSM 에이전트 설정이 유지돼야 한다."
  }
}
