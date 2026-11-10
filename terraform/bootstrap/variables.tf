variable "region" {
  description = "AWS region for shared resources."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name, used as a prefix for resource names."
  type        = string
  default     = "hello-devops"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to assume the CI roles via OIDC."
  type        = string
  default     = "Rajvira10/hello-devops"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one (only one is allowed per account)."
  type        = bool
  default     = true
}
