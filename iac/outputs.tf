# Attribute Reference

output "vpc_id" {
  description = "The ID of the Job Portal VPC"
  value       = aws_vpc.jobportal.id
}

output "cidr_block" {
  description = "cidr ipadd"
  value       = aws_vpc.jobportal.cidr_block
}