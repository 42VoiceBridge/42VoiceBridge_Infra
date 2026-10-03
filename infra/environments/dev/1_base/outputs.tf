output "vpc_id" {
  description = "생성된 VPC의 ID"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "FE·BE·AI 인스턴스용 퍼블릭 서브넷 ID (NAT가 없어 모두 퍼블릭 서브넷에 둔다)"
  value       = aws_subnet.public.id
}

output "private_subnet_ids" {
  description = "RDS/ElastiCache 서브넷 그룹용 프라이빗 서브넷 ID 목록 (서로 다른 AZ)"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "fe_sg_id" {
  description = "FE 인스턴스에 붙는 보안그룹 ID (80/443 공개)"
  value       = aws_security_group.fe.id
}

output "be_sg_id" {
  description = "BE 인스턴스에 붙는 보안그룹 ID (8080은 fe-sg에서만)"
  value       = aws_security_group.be.id
}

output "ai_sg_id" {
  description = "AI 인스턴스에 붙는 보안그룹 ID (8000은 be-sg에서만)"
  value       = aws_security_group.ai.id
}

output "rds_sg_id" {
  description = "RDS에 붙는 보안그룹 ID (be-sg에서만 3306)"
  value       = aws_security_group.rds.id
}

output "redis_sg_id" {
  description = "ElastiCache Redis에 붙는 보안그룹 ID (be-sg에서만 6379)"
  value       = aws_security_group.redis.id
}
