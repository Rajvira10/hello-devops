terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }

  # Partial configuration — the bucket/key differ per environment:
  #   terraform init -backend-config=backend/staging.s3.tfbackend
  # `use_lockfile` (in the .tfbackend files) enables S3-native state locking
  # (Terraform >= 1.10); no DynamoDB table is required.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
