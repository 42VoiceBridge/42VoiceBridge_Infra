data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 데이터 볼륨은 인스턴스와 같은 AZ여야 한다. 인스턴스 속성이 아니라 서브넷에서 AZ를
# 얻어야 volume → user_data(볼륨 ID 참조) → instance 순서가 순환 없이 성립한다.
data "aws_subnet" "app" {
  id = data.terraform_remote_state.base.outputs.public_subnet_id
}

# AI 모델 캐시, 개인화 어댑터, 프롬프트 풀 같은 상태 데이터를 보관하는 영구 볼륨.
# 인스턴스가 교체돼도 이 볼륨은 남아야 하므로 prevent_destroy를 건다.
# 의도적으로 삭제하려면 docs/AI-DEPLOYMENT.md의 "데이터 볼륨 삭제" 절차를 따른다.
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.app.availability_zone
  type              = "gp3"
  size              = var.data_volume_size_gb
  encrypted         = true

  tags = {
    Name = "${var.project_name}-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = data.terraform_remote_state.base.outputs.public_subnet_id
  vpc_security_group_ids = [data.terraform_remote_state.base.outputs.app_sg_id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.app.name

  # Containers need two hops to receive IMDSv2 token responses.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
  }

  # 최초 부팅 때만 실행된다. 데이터 볼륨 포맷·마운트 로직은 템플릿 파일에 있다.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    data_device = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"
  })

  # 참고용 태그 — 실제 연결 정보는 2_storage layer의 terraform output으로 확인
  tags = {
    Name          = "${var.project_name}-app"
    RdsEndpoint   = data.terraform_remote_state.storage.outputs.rds_endpoint
    RedisEndpoint = data.terraform_remote_state.storage.outputs.redis_endpoint
    S3Bucket      = data.terraform_remote_state.storage.outputs.s3_bucket_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.app_ssm,
    aws_iam_role_policy.secrets_access,
    aws_iam_role_policy.s3_access,
  ]
}

# Nitro(m5) 인스턴스에서는 /dev/sdf가 /dev/nvme1n1 등으로 보인다. OS 쪽에서는
# 장치 이름이 아니라 볼륨 ID 기반 /dev/disk/by-id 경로로 식별한다(user_data 참고).
resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id

  # destroy나 교체 시 인스턴스를 먼저 정지해 파일시스템이 깨진 채 분리되지 않게 한다.
  stop_instance_before_detaching = true
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-app-eip"
  }
}
