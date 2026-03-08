# =============================================================================
# Dev Environment — main.tf
# =============================================================================
# Module calls will be added starting from M2 (Terraform Foundation).
# This file establishes the env structure so CI can validate early.

terraform {
  required_version = ">= 1.5.0"

  # Remote backend will be configured in M2
  # backend "s3" {
  #   bucket         = "chatbot-platform-tfstate-dev"
  #   key            = "dev/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "chatbot-platform-tflock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "chatbot-platform"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
