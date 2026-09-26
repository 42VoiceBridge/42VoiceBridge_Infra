output "ec2_public_ip" {
  description = "Elastic IP address of the app EC2 instance"
  value       = aws_eip.app.public_ip
}
