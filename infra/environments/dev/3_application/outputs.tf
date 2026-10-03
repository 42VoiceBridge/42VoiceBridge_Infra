output "be_instance_id" {
  description = "BE instance ID used for SSM Run Command"
  value       = aws_instance.be.id
}

output "ai_instance_id" {
  description = "AI instance ID used for SSM Run Command"
  value       = aws_instance.ai.id
}

output "fe_instance_id" {
  description = "FE instance ID used for SSM Run Command"
  value       = aws_instance.fe.id
}

output "be_private_ip" {
  description = "Fixed private IP of BE"
  value       = var.be_private_ip
}

output "ai_private_ip" {
  description = "Fixed private IP of AI"
  value       = var.ai_private_ip
}

output "be_upstream" {
  description = "Where the FE edge proxies /api/* (BE private IP and port)"
  value       = "http://${var.be_private_ip}:8080"
}

output "ai_base_url" {
  description = "Value to register as AI_SERVER_BASE_URL in the app secret (BE calls AI over the VPC)"
  value       = "http://${var.ai_private_ip}:8000"
}

output "fe_public_ip" {
  description = "Elastic IP of the FE instance"
  value       = aws_eip.fe.public_ip
}

output "fe_public_host" {
  description = "Hostname the FE edge serves HTTPS for: fe_domain if set, otherwise the Elastic IP's public DNS name"
  value       = var.fe_domain != "" ? var.fe_domain : aws_eip.fe.public_dns
}

output "app_secret_name" {
  description = "Name of the manually created application secret"
  value       = var.app_secret_name
}

output "ghcr_secret_name" {
  description = "Name of the GHCR credentials secret"
  value       = var.ghcr_secret_name
}

output "data_volume_id" {
  description = "Persistent EBS volume ID mounted at /data on the AI instance"
  value       = aws_ebs_volume.data.id
}
