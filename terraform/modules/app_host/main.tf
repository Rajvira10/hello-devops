data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_vpc" "selected" {
  id      = var.vpc_id
  default = var.vpc_id == null ? true : null
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "default-for-az"
    values = var.vpc_id == null ? ["true"] : ["true", "false"]
  }
}

# Latest Amazon Linux 2023 AMI, resolved at plan time from AWS's public SSM
# parameter (no hard-coded, region-specific AMI IDs).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

locals {
  subnet_id      = coalesce(var.subnet_id, sort(data.aws_subnets.selected.ids)[0])
  log_group_name = "/${var.name}/app"
  ssm_param_path = "/${var.name}"
  ecr_registry   = split("/", var.ecr_repository_url)[0]
  container_name = "hello-devops"
  common_tags    = merge(var.tags, { Environment = var.environment })
  deploy_script = templatefile("${path.module}/templates/deploy.sh.tftpl", {
    region         = data.aws_region.current.region
    registry       = local.ecr_registry
    repository_url = var.ecr_repository_url
    log_group      = local.log_group_name
    environment    = var.environment
    log_level      = var.log_level
    memory_mb      = var.container_memory_mb
    container_name = local.container_name
    ssm_param_path = local.ssm_param_path
  })
}

# ------------------------------------------------------------ CloudWatch --
resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

# ---------------------------------------------------------- security group --
resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "hello-devops ${var.environment}: HTTP in, HTTPS out. No SSH (SSM is used)."
  vpc_id      = data.aws_vpc.selected.id
  tags        = merge(local.common_tags, { Name = "${var.name}-app" })
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(var.http_ingress_cidrs)
  security_group_id = aws_security_group.app.id
  description       = "HTTP to the app"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

# Outbound only HTTPS: ECR, S3 (image layers), SSM, CloudWatch Logs and dnf
# repos are all HTTPS. DNS (VPC resolver) and NTP (169.254.169.123) are not
# subject to security-group rules.
# Accepted risk (documented in README): restricting this further needs VPC
# interface endpoints for ECR/SSM/Logs (~$7/month each per AZ).
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs and package repos"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# ------------------------------------------------------------ app secret --
# Placeholder SecureString; the real value is set out-of-band
# (`aws ssm put-parameter --overwrite`) so it never appears in Terraform code.
resource "aws_ssm_parameter" "admin_token" {
  name        = "${local.ssm_param_path}/ADMIN_TOKEN"
  description = "Enables the app's /debug/error endpoint. Empty/placeholder = disabled."
  type        = "SecureString"
  value       = "CHANGE_ME"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

# --------------------------------------------------------------- instance --
resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  associate_public_ip_address = true
  monitoring                  = false # detailed monitoring costs extra

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    deploy_script = local.deploy_script
    image_tag     = var.image_tag
  })
  user_data_replace_on_change = true

  # IMDSv2 only, and a hop limit of 1 so containers cannot reach the
  # instance credentials through the metadata service.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  tags        = merge(local.common_tags, { Name = var.name })
  volume_tags = local.common_tags

  lifecycle {
    # A new AMI release shouldn't replace a running instance on every plan.
    ignore_changes = [ami]
  }

  depends_on = [aws_cloudwatch_log_group.app]
}
