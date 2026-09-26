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

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = data.terraform_remote_state.base.outputs.public_subnet_id
  vpc_security_group_ids = [data.terraform_remote_state.base.outputs.app_sg_id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.app.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y docker
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ec2-user
  EOF

  # 참고용 태그 — 실제 연결 정보는 2_storage layer의 terraform output으로 확인
  tags = {
    Name          = "${var.project_name}-app"
    RdsEndpoint   = data.terraform_remote_state.storage.outputs.rds_endpoint
    RedisEndpoint = data.terraform_remote_state.storage.outputs.redis_endpoint
    S3Bucket      = data.terraform_remote_state.storage.outputs.s3_bucket_name
  }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-app-eip"
  }
}
