output "instance_id" {
  description = "EC2 instance ID (GitHub environment variable EC2_INSTANCE_ID)."
  value       = aws_instance.app.id
}

output "instance_arn" {
  value = aws_instance.app.arn
}

output "public_ip" {
  value = aws_instance.app.public_ip
}

output "app_url" {
  description = "Public URL of the app (GitHub environment variable APP_URL)."
  value       = "http://${aws_instance.app.public_dns}"
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "security_group_id" {
  value = aws_security_group.app.id
}

output "admin_token_parameter" {
  value = aws_ssm_parameter.admin_token.name
}
