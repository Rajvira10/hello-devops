variable "name" {
  description = "Base name for resources, e.g. hello-devops-staging."
  type        = string
}

variable "environment" {
  description = "Environment name (staging or production)."
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "vpc_id" {
  description = "VPC to launch into. Null = the region's default VPC."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet for the instance. Null = first default subnet of the VPC."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "architecture" {
  description = "CPU architecture of the instance type: x86_64 or arm64 (the image is multi-arch)."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64."
  }
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size."
  type        = number
  default     = 16
}

variable "http_ingress_cidrs" {
  description = "CIDRs allowed to reach the app on port 80."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository the instance may pull from."
  type        = string
}

variable "ecr_repository_url" {
  description = "URL of the ECR repository (…dkr.ecr.<region>.amazonaws.com/<name>)."
  type        = string
}

variable "image_tag" {
  description = "Image tag deployed at first boot. Later deploys come from CI via SSM."
  type        = string
}

variable "log_level" {
  description = "App LOG_LEVEL."
  type        = string
  default     = "info"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for container logs."
  type        = number
  default     = 14
}

variable "container_memory_mb" {
  description = "Memory limit for the app container."
  type        = number
  default     = 256
}

variable "tags" {
  description = "Extra tags for all resources."
  type        = map(string)
  default     = {}
}
