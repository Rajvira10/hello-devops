variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name prefix."
  type        = string
  default     = "hello-devops"
}

variable "environment" {
  description = "staging or production."
  type        = string
}

variable "github_repository" {
  description = "owner/name of the GitHub repo whose environment may deploy here."
  type        = string
  default     = "Rajvira10/hello-devops"
}

variable "ecr_repository_name" {
  description = "ECR repository created by the bootstrap stack."
  type        = string
  default     = "hello-devops"
}

variable "image_tag" {
  description = "Image tag deployed at first boot (CI deploys subsequent versions)."
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "architecture" {
  type    = string
  default = "x86_64"
}

variable "http_ingress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "log_level" {
  type    = string
  default = "info"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "container_memory_mb" {
  type    = number
  default = 256
}
