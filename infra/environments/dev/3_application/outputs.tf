output "ec2_public_ip" {
  description = "Elastic IP address of the app EC2 instance"
  value       = aws_eip.app.public_ip
}

output "ec2_instance_id" {
  description = "Instance ID used for SSM Run Command"
  value       = aws_instance.app.id
}

output "app_secret_name" {
  description = "Name of the manually created application secret"
  value       = var.app_secret_name
}
