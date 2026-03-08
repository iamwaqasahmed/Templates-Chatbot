# =============================================================================
# Staging Environment — main.tf
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "chatbot-platform"
      Environment = "staging"
      ManagedBy   = "terraform"
    }
  }
}
