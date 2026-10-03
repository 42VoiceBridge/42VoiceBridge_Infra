# BE 인스턴스. 인터넷에 직접 공개하지 않는다(be-sg는 fe-sg에서 8080만 허용).
# 고정 사설 IP 덕분에 교체해도 FE 프록시 목적지(http://<be_private_ip>:8080)가 바뀌지 않는다.
resource "aws_instance" "be" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.be_instance_type
  subnet_id              = local.subnet_id
  private_ip             = var.be_private_ip
  vpc_security_group_ids = [data.terraform_remote_state.base.outputs.be_sg_id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.node["be"].name

  # Containers need two hops to receive IMDSv2 token responses.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.be_root_volume_size_gb
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    data_device = ""
  })
  # cloud-init은 인스턴스당 한 번만 user_data를 실행한다. 바뀐 스크립트가 실제로 적용되도록
  # user_data 변경 시 in-place 업데이트 대신 교체를 강제한다.
  user_data_replace_on_change = true

  # 참고용 태그 — 실제 연결 정보는 2_storage layer의 terraform output으로 확인
  tags = {
    Name          = "${var.project_name}-be"
    Role          = "be"
    RdsEndpoint   = data.terraform_remote_state.storage.outputs.rds_endpoint
    RedisEndpoint = data.terraform_remote_state.storage.outputs.redis_endpoint
    S3Bucket      = data.terraform_remote_state.storage.outputs.s3_bucket_name
  }

  lifecycle {
    # most_recent AMI는 새 이미지가 나올 때마다 변경으로 보여 인스턴스 교체를 계획한다.
    # 교체(데이터 영향, 재배포)는 의도했을 때만 하도록 AMI 변경은 무시한다. 부팅 시 dnf update로 패치한다.
    ignore_changes = [ami]

    precondition {
      condition     = startswith(var.be_private_ip, local.subnet_prefix)
      error_message = "be_private_ip must be inside the public subnet CIDR."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.common,
    aws_iam_role_policy.be,
  ]
}
