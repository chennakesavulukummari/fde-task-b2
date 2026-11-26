# Creating VPC
resource "aws_vpc" "jobportal" {
  cidr_block       = var.cidr_block
  instance_tenancy = "default"

  # Argument Reference

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "cloudbinary-dev-us-east-1-jobportal-vpc"
    Environment = "dev"
    Owner       = "platform-jobportal@cloudbinary.in"
    Application = "Job Portal"
    CostCenter  = "CC-2026"
    ManagedBy   = "terraform"
  }
}

# Attribute Reference