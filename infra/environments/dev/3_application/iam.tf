data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.project_name}-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "s3_access" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket"]
    resources = [data.terraform_remote_state.storage.outputs.s3_bucket_arn]
  }

  statement {
    sid       = "ReadWriteObjects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${data.terraform_remote_state.storage.outputs.s3_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "s3_access" {
  name   = "${var.project_name}-s3-access"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.s3_access.json
}

# RDS 마스터 비밀번호는 Secrets Manager가 자동 관리 — EC2가 해당 시크릿을
# 직접 조회할 수 있도록 읽기 권한만 최소로 부여
data "aws_iam_policy_document" "secrets_access" {
  statement {
    sid       = "ReadRdsSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.terraform_remote_state.storage.outputs.rds_secret_arn]
  }
}

resource "aws_iam_role_policy" "secrets_access" {
  name   = "${var.project_name}-secrets-access"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.secrets_access.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-app-profile"
  role = aws_iam_role.app.name
}
