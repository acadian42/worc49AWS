terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  # GovCloud: routes all API calls through FIPS 140-2 validated endpoints.
  # Set to false only if FIPS is explicitly not required by your compliance posture.
  use_fips_endpoint = var.use_fips_endpoint

  default_tags {
    tags = var.default_tags
  }
}
