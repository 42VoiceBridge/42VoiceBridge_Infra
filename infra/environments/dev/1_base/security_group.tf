# 3대 인스턴스(ADR 0006) 보안그룹. 트래픽은 한 방향으로만 흐른다.
#   인터넷 → fe-sg(80/443) → be-sg(8080) → ai-sg(8000), be-sg → rds-sg/redis-sg
# SG 참조 체인에 순환이 없도록 fe → be → ai 순서로 선언한다.

# fe-sg — FE 인스턴스. 사용자 브라우저가 접속하는 유일한 공개 진입점이다.
# 80은 Let's Encrypt HTTP-01 인증서 발급·갱신과 https 리다이렉트에 필요하다.
# SSH는 열지 않고 SSM으로만 접근한다.
resource "aws_security_group" "fe" {
  name        = "${var.project_name}-fe-sg"
  description = "Security group for the FE instance (public edge)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP (ACME HTTP-01 challenge and redirect to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-fe-sg"
  }
}

# be-sg — BE 인스턴스. 인터넷에 직접 공개하지 않고 FE의 프록시(/api)만 받는다.
# 호스트 8080 = 컨테이너 8080(deploy-ec2.sh의 --publish 8080:8080)과 반드시 일치해야 한다.
resource "aws_security_group" "be" {
  name        = "${var.project_name}-be-sg"
  description = "Security group for the BE instance (reachable from FE only)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "BE API from fe-sg only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.fe.id]
  }

  # SSM 검증 전까지 BE에만 제한된 CIDR의 SSH를 유지한다(ADR 0004).
  ingress {
    description = "SSH from allowed CIDR only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-be-sg"
  }
}

# ai-sg — AI 인스턴스. 인증이 없는 서비스이므로 이 규칙이 유일한 접근 통제다.
# BE 보안그룹 외에는 8000을 열지 않는다. SSH도 열지 않는다.
resource "aws_security_group" "ai" {
  name        = "${var.project_name}-ai-sg"
  description = "Security group for the AI inference instance (reachable from BE only)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "AI API from be-sg only"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.be.id]
  }

  # GHCR 이미지 pull, Hugging Face 모델 다운로드, SSM 연결에 아웃바운드가 필요하다.
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ai-sg"
  }
}

# rds-sg — attached to the RDS instance, only reachable from be-sg
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for the RDS MySQL instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from be-sg only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.be.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# redis-sg — attached to the ElastiCache Redis node, only reachable from be-sg
resource "aws_security_group" "redis" {
  name        = "${var.project_name}-redis-sg"
  description = "Security group for the ElastiCache Redis node"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Redis from be-sg only"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.be.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-redis-sg"
  }
}
