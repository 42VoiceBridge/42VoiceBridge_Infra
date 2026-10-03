# AWS 자격 증명 없이 보안그룹 접근 체인을 검증한다(mock 프로바이더).
# 목표 체인: 인터넷 → fe(80/443) → be(8080) → ai(8000), be → rds(3306) / redis(6379)
# 실행: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
    }
  }
}

variables {
  ssh_allowed_cidr = "203.0.113.5/32"
}

run "FE만_인터넷에_80_443을_연다" {
  command = apply

  assert {
    condition     = toset([for r in aws_security_group.fe.ingress : r.from_port]) == toset([80, 443])
    error_message = "fe-sg는 80/443만 열어야 한다."
  }
  assert {
    condition     = alltrue([for r in aws_security_group.fe.ingress : contains(r.cidr_blocks, "0.0.0.0/0")])
    error_message = "fe-sg의 80/443은 공개여야 한다(Let's Encrypt HTTP-01에 필요)."
  }
}

run "BE는_FE에서만_8080을_받고_SSH는_제한된_CIDR만" {
  command = apply

  assert {
    condition     = toset([for r in aws_security_group.be.ingress : r.from_port]) == toset([8080, 22])
    error_message = "be-sg는 8080과 22만 열어야 한다."
  }
  assert {
    condition     = alltrue([for r in aws_security_group.be.ingress : r.from_port == 8080 ? (contains(coalesce(r.security_groups, []), aws_security_group.fe.id) && length(coalesce(r.cidr_blocks, [])) == 0) : true])
    error_message = "BE 8080은 fe-sg에서만 허용해야 한다(인터넷 직접 공개 금지)."
  }
  assert {
    condition     = alltrue([for r in aws_security_group.be.ingress : r.from_port == 22 ? (r.cidr_blocks == tolist(["203.0.113.5/32"])) : true])
    error_message = "BE의 SSH는 지정한 CIDR만 허용해야 한다."
  }
}

run "AI는_BE에서만_8000을_받고_SSH가_없다" {
  command = apply

  assert {
    condition     = length(aws_security_group.ai.ingress) == 1 && one(aws_security_group.ai.ingress).from_port == 8000 && one(aws_security_group.ai.ingress).to_port == 8000
    error_message = "ai-sg는 8000 하나만 열어야 하며 SSH가 없어야 한다."
  }
  assert {
    condition     = contains(coalesce(one(aws_security_group.ai.ingress).security_groups, []), aws_security_group.be.id) && length(coalesce(one(aws_security_group.ai.ingress).cidr_blocks, [])) == 0
    error_message = "AI 8000은 be-sg에서만 허용해야 한다(인증이 없어 이 규칙이 유일한 방어선)."
  }
}

run "RDS와_Redis는_BE에서만_접근된다" {
  command = apply

  assert {
    condition     = one(aws_security_group.rds.ingress).from_port == 3306 && contains(coalesce(one(aws_security_group.rds.ingress).security_groups, []), aws_security_group.be.id) && length(coalesce(one(aws_security_group.rds.ingress).cidr_blocks, [])) == 0
    error_message = "RDS는 be-sg에서만 3306을 받아야 한다."
  }
  assert {
    condition     = one(aws_security_group.redis.ingress).from_port == 6379 && contains(coalesce(one(aws_security_group.redis.ingress).security_groups, []), aws_security_group.be.id) && length(coalesce(one(aws_security_group.redis.ingress).cidr_blocks, [])) == 0
    error_message = "Redis는 be-sg에서만 6379를 받아야 한다."
  }
}

run "SG_출력이_세_인스턴스용으로_노출된다" {
  command = apply

  assert {
    condition     = output.fe_sg_id == aws_security_group.fe.id && output.be_sg_id == aws_security_group.be.id && output.ai_sg_id == aws_security_group.ai.id
    error_message = "fe_sg_id, be_sg_id, ai_sg_id 출력이 필요하다."
  }
}
