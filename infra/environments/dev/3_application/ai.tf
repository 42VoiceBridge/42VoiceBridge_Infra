# AI 추론 서버 인스턴스. 8000은 ai-sg가 be-sg에게만 연다. 고정 사설 IP를 AI_SERVER_BASE_URL로 등록한다.
# 상태 데이터(HF 모델 캐시, 개인화 어댑터, 등록 음성, 학습 작업, 프롬프트 풀)는 별도 EBS 볼륨의 /data에 둔다.

# 데이터 볼륨은 인스턴스와 같은 AZ여야 한다. 인스턴스 속성이 아니라 서브넷에서 AZ를 얻어야
# volume → user_data(볼륨 ID 참조) → instance 순서가 순환 없이 성립한다.
# prevent_destroy는 리소스 블록이 설정에 있을 때만 막는다. 블록을 지우면 그대로 삭제가 계획되므로
# 영구 보호가 아니다. 그래서 DLM 일일 스냅샷과 삭제 전 최종 스냅샷 절차를 함께 둔다(docs/DATA-PROTECTION.md).
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.app.availability_zone
  type              = "gp3"
  size              = var.data_volume_size_gb
  encrypted         = true
  snapshot_id       = var.data_snapshot_id != "" ? var.data_snapshot_id : null

  tags = {
    Name   = "${var.project_name}-ai-data"
    Backup = "ai-data" # DLM 스냅샷 정책의 대상 태그
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "ai" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.ai_instance_type
  subnet_id              = local.subnet_id
  private_ip             = var.ai_private_ip
  vpc_security_group_ids = [data.terraform_remote_state.base.outputs.ai_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.node["ai"].name
  # key_name 없음: SSH를 쓰지 않고 SSM으로만 접근한다.

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.ai_root_volume_size_gb
  }

  # 최초 부팅 때만 실행된다. 데이터 볼륨 포맷·마운트 로직은 템플릿 파일에 있다.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    data_device = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"
  })
  # cloud-init은 인스턴스당 한 번만 user_data를 실행한다. 바뀐 스크립트가 실제로 적용되도록
  # user_data 변경 시 in-place 업데이트 대신 교체를 강제한다.
  user_data_replace_on_change = true

  tags = {
    Name = "${var.project_name}-ai"
    Role = "ai"
  }

  lifecycle {
    # most_recent AMI는 새 이미지가 나올 때마다 변경으로 보여 인스턴스 교체를 계획한다.
    # 교체(데이터 영향, 재배포)는 의도했을 때만 하도록 AMI 변경은 무시한다. 부팅 시 dnf update로 패치한다.
    ignore_changes = [ami]

    precondition {
      condition     = startswith(var.ai_private_ip, local.subnet_prefix)
      error_message = "ai_private_ip must be inside the public subnet CIDR."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.common,
    aws_iam_role_policy.ai,
  ]
}

# Nitro(m5) 인스턴스에서는 /dev/sdf가 /dev/nvme1n1 등으로 보인다. OS 쪽에서는
# 장치 이름이 아니라 볼륨 ID 기반 /dev/disk/by-id 경로로 식별한다(user_data 참고).
resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.ai.id

  # destroy나 교체 시 인스턴스를 먼저 정지해 파일시스템이 깨진 채 분리되지 않게 한다.
  stop_instance_before_detaching = true
}

# 데이터 볼륨 일일 스냅샷(DLM). Backup=ai-data 태그가 붙은 볼륨만 대상이다.
# DLM은 자신이 만든 스냅샷만 보존 개수에 따라 지운다. 수동으로 만든 스냅샷은 지우지 않는다.
data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.project_name}-dlm-role"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "ai_data" {
  description        = "Daily snapshots of the AI data volume"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "ai-data"
    }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["18:00"] # UTC 18:00 = 한국 시간 03:00
      }

      retain_rule {
        count = var.data_snapshot_retention
      }

      copy_tags = true

      tags_to_add = {
        SnapshotCreator = "dlm"
      }
    }
  }
}
