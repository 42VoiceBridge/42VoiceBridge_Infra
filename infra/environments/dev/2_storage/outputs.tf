output "rds_endpoint" {
  description = "Connection endpoint for the RDS MySQL instance"
  value       = aws_db_instance.main.endpoint
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN holding the auto-generated RDS master password"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "redis_endpoint" {
  description = "Configuration endpoint (host) for the ElastiCache Redis node"
  value       = aws_elasticache_cluster.main.cache_nodes[0].address
}

output "redis_port" {
  description = "Port for the ElastiCache Redis node"
  value       = aws_elasticache_cluster.main.cache_nodes[0].port
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket used for recordings/TTS audio"
  value       = aws_s3_bucket.recordings.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket used for recordings/TTS audio"
  value       = aws_s3_bucket.recordings.arn
}
