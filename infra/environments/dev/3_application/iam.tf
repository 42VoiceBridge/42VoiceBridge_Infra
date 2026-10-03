# 인스턴스별 최소 권한 역할(ADR 0006).
#   공통  : SSM 관리 대상 등록, 배포 스크립트(deploy/scripts/*) 다운로드, GHCR 시크릿 읽기
#   BE    : 앱 시크릿, RDS 관리형 시크릿, 앱 버킷 읽기·쓰기
#   AI    : 프롬프트 풀(ai/*) 읽기
#   FE    : 공통만
# 배포 스크립트는 run.sh가 앱 버킷 deploy/scripts/에 올리고 각 인스턴스가 내려받아 실행하므로
# 세 역할 모두 s3:GetObject가 필요하다. 하나라도 빠지면 그 인스턴스 배포가 첫 단계에서 실패한다.

data "aws_caller_identity" "current" {}

locals {
  roles = toset(["be", "ai", "fe"])

  bucket_arn   = data.terraform_remote_state.storage.outputs.s3_bucket_arn
  secret_arn   = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret"
  ghcr_secret  = "${local.secret_arn}:${var.ghcr_secret_name}-*"
  app_secret   = "${local.secret_arn}:${var.app_secret_name}-*"
  rds_secret   = data.terraform_remote_state.storage.outputs.rds_secret_arn
  deploy_paths = ["${local.bucket_arn}/deploy/scripts/*"]
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  for_each           = local.roles
  name               = "${var.project_name}-${each.key}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.roles
  name     = "${var.project_name}-${each.key}-profile"
  role     = aws_iam_role.node[each.key].name
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each   = local.roles
  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 공통: 배포 스크립트 다운로드 + GHCR 자격 증명 읽기
resource "aws_iam_role_policy" "common" {
  for_each = local.roles
  name     = "${var.project_name}-${each.key}-common"
  role     = aws_iam_role.node[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DownloadDeployScripts"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = local.deploy_paths
      },
      {
        Sid      = "ReadGhcrSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [local.ghcr_secret]
      },
    ]
  })
}

# BE: 앱 버킷 읽기·쓰기, 앱 시크릿, RDS 관리형 시크릿.
# 전환 기간에는 GHCR 자격 증명이 앱 시크릿에 남아 있을 수 있어(deploy-ec2.sh가 폴백) 앱 시크릿 읽기가 필요하다.
resource "aws_iam_role_policy" "be" {
  name = "${var.project_name}-be-app"
  role = aws_iam_role.node["be"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.bucket_arn]
      },
      {
        Sid      = "ReadWriteObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = ["${local.bucket_arn}/*"]
      },
      {
        Sid      = "ReadRdsSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [local.rds_secret]
      },
      {
        Sid      = "ReadAppSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [local.app_secret]
      },
    ]
  })
}

# AI: 프롬프트 풀(ai/script_pool.json)만 읽는다. 녹음 데이터(그 외 키)는 읽지 못한다.
# HeadObject로 존재 여부를 확인하므로 ai/ 접두사에 한해 ListBucket도 허용한다.
resource "aws_iam_role_policy" "ai" {
  name = "${var.project_name}-ai-pool"
  role = aws_iam_role.node["ai"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadPromptPool"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${local.bucket_arn}/ai/*"]
      },
      {
        Sid       = "ListAiPrefix"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = [local.bucket_arn]
        Condition = { StringLike = { "s3:prefix" = ["ai/*"] } }
      },
    ]
  })
}
