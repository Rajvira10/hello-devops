data "aws_ecr_repository" "app" {
  name = var.ecr_repository_name
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

module "app_host" {
  source = "../modules/app_host"

  name                = "${var.project}-${var.environment}"
  environment         = var.environment
  instance_type       = var.instance_type
  architecture        = var.architecture
  http_ingress_cidrs  = var.http_ingress_cidrs
  ecr_repository_arn  = data.aws_ecr_repository.app.arn
  ecr_repository_url  = data.aws_ecr_repository.app.repository_url
  image_tag           = var.image_tag
  log_level           = var.log_level
  log_retention_days  = var.log_retention_days
  container_memory_mb = var.container_memory_mb
}

# ------------------------------------------------- CI deploy role (OIDC) --
# Only jobs that run in the matching GitHub *environment* (which can require
# manual approval for production) can assume this role, and the role can only
# run commands on this environment's instance.

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.environment}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.project}-${var.environment}-ci-deploy"
  description          = "GitHub Actions deploys to ${var.environment} via SSM Run Command"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid     = "RunDeployOnThisInstanceOnly"
    actions = ["ssm:SendCommand"]
    resources = [
      module.app_host.instance_arn,
      "arn:aws:ssm:${var.region}::document/AWS-RunShellScript",
    ]
  }
  statement {
    sid       = "ReadCommandResults"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"] # not resource-scopable
  }
  statement {
    sid       = "ReadImageMetadata"
    actions   = ["ecr:DescribeImages"]
    resources = [data.aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-via-ssm"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
