variable "aws_region" {
  description = "The AWS region to deploy resources in"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "The type of instance to create"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "The name of the SSH key pair to use"
  type        = string
  default     = "cf36-aws-nv-sshkeys"
}