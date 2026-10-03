# FE 인스턴스. 공개 진입점이다: Caddy(엣지)가 80/443을 받아 Let's Encrypt 인증서를 자동 발급·갱신하고,
# /api/* 는 BE 사설 IP로, 나머지는 FE(nginx) 컨테이너로 프록시한다. SSH 없이 SSM으로만 접근한다.
resource "aws_instance" "fe" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.fe_instance_type
  subnet_id              = local.subnet_id
  private_ip             = var.fe_private_ip
  vpc_security_group_ids = [data.terraform_remote_state.base.outputs.fe_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.node["fe"].name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.fe_root_volume_size_gb
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    data_device = ""
  })
  # cloud-init은 인스턴스당 한 번만 user_data를 실행한다. 바뀐 스크립트가 실제로 적용되도록
  # user_data 변경 시 in-place 업데이트 대신 교체를 강제한다.
  user_data_replace_on_change = true

  tags = {
    Name = "${var.project_name}-fe"
    Role = "fe"
  }

  lifecycle {
    # most_recent AMI는 새 이미지가 나올 때마다 변경으로 보여 인스턴스 교체를 계획한다.
    # 교체(데이터 영향, 재배포)는 의도했을 때만 하도록 AMI 변경은 무시한다. 부팅 시 dnf update로 패치한다.
    ignore_changes = [ami]

    precondition {
      condition     = startswith(var.fe_private_ip, local.subnet_prefix)
      error_message = "fe_private_ip must be inside the public subnet CIDR."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.common,
  ]
}

# 안정적인 공인 주소. 인스턴스와 분리해 만들고 연결한다(연결을 바꿔도 주소가 유지된다).
resource "aws_eip" "fe" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-fe-eip"
  }
}

resource "aws_eip_association" "fe" {
  instance_id   = aws_instance.fe.id
  allocation_id = aws_eip.fe.id
}
