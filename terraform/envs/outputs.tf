output "instance_id" {
  description = "→ GitHub environment variable EC2_INSTANCE_ID"
  value       = module.app_host.instance_id
}

output "app_url" {
  description = "→ GitHub environment variable APP_URL"
  value       = module.app_host.app_url
}

output "deploy_role_arn" {
  description = "→ GitHub environment variable AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}

output "log_group_name" {
  value = module.app_host.log_group_name
}

output "admin_token_parameter" {
  description = "Set the real value with: aws ssm put-parameter --overwrite --type SecureString --name <this> --value <token>"
  value       = module.app_host.admin_token_parameter
}
