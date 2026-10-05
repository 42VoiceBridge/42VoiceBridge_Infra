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
      cidr_block        = "10.0.1.0/24"
    }
  }
  mock_resource "aws_ebs_volume" {
    defaults = {
      id = "vol-0abc123def4567890"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
  mock_resource "aws_eip" {
    defaults = {
      public_ip  = "203.0.113.10"
      public_dns = "ec2-203-0-113-10.ap-northeast-2.compute.amazonaws.com"
    }
  }
}

override_data {
  target = data.terraform_remote_state.base
  values = {
    outputs = {
      public_subnet_id = "subnet-0123456789abcdef0"
      fe_sg_id         = "sg-0fe00000000000000"
      be_sg_id         = "sg-0be00000000000000"
      ai_sg_id         = "sg-0ai00000000000000"
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

run "세_인스턴스는_기본_사양과_고정_사설_IP를_갖는다" {
  command = plan

  assert {
    condition     = aws_instance.be.private_ip == "10.0.1.10" && aws_instance.ai.private_ip == "10.0.1.20" && aws_instance.fe.private_ip == "10.0.1.30"
    error_message = "BE, AI, FE는 고정 사설 IP(10/20/30)를 가져야 한다."
  }
  assert {
    condition     = aws_instance.be.instance_type == "t3.small" && aws_instance.ai.instance_type == "t3.small" && aws_instance.fe.instance_type == "t3.small"
    error_message = "현재 시험 사양은 Free Tier 제한으로 BE/AI/FE 모두 t3.small이다(docs/FOLLOW-UPS.md, 정식 사양 미확정)."
  }
  assert {
    condition     = aws_instance.be.root_block_device[0].volume_size == 30 && aws_instance.ai.root_block_device[0].volume_size == 40 && aws_instance.fe.root_block_device[0].volume_size == 30
    error_message = "root 볼륨은 BE 30, AI 40, FE 30 GiB여야 한다."
  }
}

run "SSH_키는_BE에만_있다" {
  # key_name은 설정하지 않으면 plan 시점에 미확정이다. mock apply에서는 설정하지 않은 값이
  # 임의 문자열이 되므로, AI·FE가 SSH 키 변수를 쓰고 있다면 "test-key"와 같아져 실패한다.
  command = apply

  assert {
    condition     = aws_instance.be.key_name == "test-key"
    error_message = "BE는 SSH 키를 가져야 한다."
  }
  assert {
    condition     = aws_instance.ai.key_name != "test-key" && aws_instance.fe.key_name != "test-key"
    error_message = "AI와 FE는 SSH 키 없이 SSM으로만 접근해야 한다."
  }
}

run "인스턴스마다_자기_보안그룹을_쓴다" {
  command = plan

  assert {
    condition     = contains(aws_instance.fe.vpc_security_group_ids, "sg-0fe00000000000000") && length(aws_instance.fe.vpc_security_group_ids) == 1
    error_message = "FE는 fe-sg만 써야 한다."
  }
  assert {
    condition     = contains(aws_instance.be.vpc_security_group_ids, "sg-0be00000000000000") && length(aws_instance.be.vpc_security_group_ids) == 1
    error_message = "BE는 be-sg만 써야 한다."
  }
  assert {
    condition     = contains(aws_instance.ai.vpc_security_group_ids, "sg-0ai00000000000000") && length(aws_instance.ai.vpc_security_group_ids) == 1
    error_message = "AI는 ai-sg만 써야 한다."
  }
}

run "데이터_볼륨과_스냅샷_정책" {
  command = plan

  assert {
    condition     = aws_ebs_volume.data.size == 20 && aws_ebs_volume.data.type == "gp3" && aws_ebs_volume.data.encrypted
    error_message = "데이터 볼륨은 암호화된 gp3 20GiB여야 한다."
  }
  assert {
    condition     = aws_ebs_volume.data.availability_zone == "ap-northeast-2a"
    error_message = "볼륨 AZ는 앱 서브넷의 AZ여야 한다(인스턴스 속성 참조 시 순환)."
  }
  assert {
    condition     = aws_ebs_volume.data.tags["Backup"] == "ai-data"
    error_message = "DLM 대상 태그(Backup=ai-data)가 있어야 한다."
  }
  assert {
    condition     = aws_volume_attachment.data.device_name == "/dev/sdf" && aws_volume_attachment.data.stop_instance_before_detaching
    error_message = "분리 전 인스턴스 정지 옵션이 필요하다."
  }
  assert {
    condition     = one(aws_dlm_lifecycle_policy.ai_data.policy_details).target_tags["Backup"] == "ai-data" && one(one(aws_dlm_lifecycle_policy.ai_data.policy_details).schedule).retain_rule[0].count == 7
    error_message = "일일 스냅샷 7개 보존 정책이 데이터 볼륨 태그를 대상으로 해야 한다."
  }
}

run "스냅샷_ID를_주면_그_스냅샷에서_볼륨을_만든다" {
  command = plan

  variables {
    data_snapshot_id = "snap-0123456789abcdef0"
  }

  assert {
    condition     = aws_ebs_volume.data.snapshot_id == "snap-0123456789abcdef0"
    error_message = "data_snapshot_id를 주면 볼륨이 그 스냅샷에서 복원돼야 한다."
  }
}

run "잘못된_스냅샷_ID_형식은_거부된다" {
  command = plan

  variables {
    data_snapshot_id = "vol-0123456789abcdef0"
  }

  expect_failures = [var.data_snapshot_id]
}

run "IAM_정책은_역할마다_최소_권한이다" {
  command = plan

  # 세 역할 모두 배포 스크립트 다운로드와 GHCR 시크릿 읽기가 필요하다.
  assert {
    condition     = alltrue([for r in ["be", "ai", "fe"] : strcontains(aws_iam_role_policy.common[r].policy, "voicebridge-recordings-test/deploy/scripts/*")])
    error_message = "모든 역할에 deploy/scripts/* s3:GetObject가 있어야 한다(없으면 해당 인스턴스 배포가 첫 단계에서 실패)."
  }
  assert {
    condition     = alltrue([for r in ["be", "ai", "fe"] : strcontains(aws_iam_role_policy.common[r].policy, "secret:voicebridge/dev/ghcr-*")])
    error_message = "모든 역할이 GHCR 시크릿을 읽을 수 있어야 한다."
  }
  assert {
    condition     = alltrue([for r in ["be", "ai", "fe"] : !strcontains(aws_iam_role_policy.common[r].policy, "voicebridge/dev/app")])
    error_message = "공통 정책이 BE 앱 시크릿을 포함하면 안 된다."
  }
  # AI는 ai/* 만 읽고 녹음 버킷 전체 접근은 없다.
  assert {
    condition     = strcontains(aws_iam_role_policy.ai.policy, "voicebridge-recordings-test/ai/*") && !strcontains(aws_iam_role_policy.ai.policy, "s3:PutObject") && !strcontains(aws_iam_role_policy.ai.policy, "secretsmanager")
    error_message = "AI 역할은 ai/* 읽기만 가져야 한다."
  }
  # BE만 앱 시크릿, RDS 시크릿, 버킷 읽기·쓰기를 가진다.
  assert {
    condition     = strcontains(aws_iam_role_policy.be.policy, "voicebridge/dev/app-*") && strcontains(aws_iam_role_policy.be.policy, "rds-test") && strcontains(aws_iam_role_policy.be.policy, "s3:PutObject")
    error_message = "BE 역할은 앱 시크릿, RDS 시크릿, 버킷 쓰기를 가져야 한다."
  }
  assert {
    condition     = length([for k, v in aws_iam_role.node : k]) == 3
    error_message = "역할은 be, ai, fe 3개여야 한다."
  }
}

run "출력_주소가_고정값으로_조립된다" {
  command = plan

  assert {
    condition     = output.ai_base_url == "http://10.0.1.20:8000"
    error_message = "ai_base_url은 AI 고정 사설 IP의 8000이어야 한다."
  }
  assert {
    condition     = output.be_upstream == "http://10.0.1.10:8080"
    error_message = "be_upstream은 BE 고정 사설 IP의 8080이어야 한다(be-sg, 스크립트 게시 포트와 일치)."
  }
}

run "도메인이_없으면_EIP_공개_DNS를_쓴다" {
  command = apply

  variables {
    fe_domain = ""
  }

  assert {
    condition     = output.fe_public_host == "ec2-203-0-113-10.ap-northeast-2.compute.amazonaws.com"
    error_message = "fe_domain이 비어 있으면 EIP의 공개 DNS 이름을 써야 한다."
  }
}

run "도메인이_있으면_도메인을_쓴다" {
  command = apply

  variables {
    fe_domain = "app.example.com"
  }

  assert {
    condition     = output.fe_public_host == "app.example.com"
    error_message = "fe_domain이 있으면 그 값을 써야 한다."
  }
}

run "user_data는_AI에만_볼륨_마운트를_넣는다" {
  # 새 볼륨 ID는 plan 시점에 미확정이라 user_data를 평가하려면 apply(mock)가 필요하다.
  command = apply

  assert {
    condition     = strcontains(aws_instance.ai.user_data, "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0abc123def4567890")
    error_message = "AI의 장치 경로는 하이픈 없는 볼륨 ID 기반 by-id 경로여야 한다."
  }
  assert {
    condition     = strcontains(aws_instance.ai.user_data, "blkid -p") && strcontains(aws_instance.ai.user_data, "refusing to format")
    error_message = "기존 시그니처가 있으면 포맷하지 않는 보호 로직이 있어야 한다."
  }
  assert {
    condition     = strcontains(aws_instance.ai.user_data, "UUID=$uuid") && strcontains(aws_instance.ai.user_data, "nofail")
    error_message = "fstab은 UUID와 nofail로 등록해야 한다."
  }
  assert {
    condition     = !strcontains(aws_instance.be.user_data, "mount_data_volume") && !strcontains(aws_instance.fe.user_data, "mount_data_volume")
    error_message = "BE와 FE에는 데이터 볼륨 마운트 로직이 없어야 한다."
  }
  assert {
    condition     = alltrue([for u in [aws_instance.be.user_data, aws_instance.ai.user_data, aws_instance.fe.user_data] : strcontains(u, "amazon-ssm-agent") && strcontains(u, "dnf install -y --allowerasing docker")])
    error_message = "세 인스턴스 모두 Docker와 SSM 에이전트를 설치해야 한다."
  }
}

run "사설_IP가_서로_겹치면_거부된다" {
  command = plan

  variables {
    ai_private_ip = "10.0.1.10"
  }

  expect_failures = [var.ai_private_ip]
}

run "예약_주소나_다른_대역은_거부된다" {
  command = plan

  variables {
    be_private_ip = "10.0.1.2"
  }

  expect_failures = [var.be_private_ip]
}

run "서브넷_밖의_IP는_거부된다" {
  command = plan

  override_data {
    target = data.aws_subnet.app
    values = {
      availability_zone = "ap-northeast-2a"
      cidr_block        = "10.0.2.0/24"
    }
  }

  expect_failures = [aws_instance.be, aws_instance.ai, aws_instance.fe]
}

run "잘못된_도메인_형식은_거부된다" {
  command = plan

  variables {
    fe_domain = "Bad_Domain"
  }

  expect_failures = [var.fe_domain]
}
