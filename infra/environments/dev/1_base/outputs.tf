output "vpc_id" {
  description = "생성된 VPC의 ID"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "EC2 앱 서버용 퍼블릭 서브넷 ID"
  value       = aws_subnet.public.id
}

output "private_subnet_ids" {
  description = "RDS/ElastiCache 서브넷 그룹용 프라이빗 서브넷 ID 목록 (서로 다른 AZ)"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "app_sg_id" {
  description = "EC2 앱 서버에 붙는 보안그룹 ID"
  value       = aws_security_group.app.id
}

output "rds_sg_id" {
  description = "RDS에 붙는 보안그룹 ID"
  value       = aws_security_group.rds.id
}

output "redis_sg_id" {
  description = "ElastiCache Redis에 붙는 보안그룹 ID"
  value       = aws_security_group.redis.id
}
