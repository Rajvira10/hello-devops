output "state_bucket" {
  description = "Use as `bucket` in envs/backend/*.s3.tfbackend."
  value       = aws_s3_bucket.state.bucket
}

output "ecr_repository_url" {
  description = "Set as the ECR_REPOSITORY GitHub variable (name part) and in envs tfvars."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_arn" {
  value = aws_ecr_repository.app.arn
}

output "ci_push_role_arn" {
  description = "Set as the AWS_PUSH_ROLE_ARN GitHub repository variable."
  value       = aws_iam_role.ci_push.arn
}

output "github_oidc_provider_arn" {
  value = local.github_oidc_arn
}
