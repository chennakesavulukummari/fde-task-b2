/*
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["225989338000"] # Canonical
}
*/
resource "aws_instance" "example" {
  #ami           = data.aws_ami.ubuntu.id
  ami           = "ami-0c30b7300f5fb34cd"
  instance_type = var.instance_type
  region        = var.aws_region

  # SSH Key Pair
  key_name = var.key_name # Replace with your actual key pair name

  # Networking
  vpc_security_group_ids = ["sg-0a517b5997d1aa81c"]

  subnet_id = "subnet-065e5315bbd873c9e"

  associate_public_ip_address = true

  tags = {
    Name               = "HelloWorld"
    ProjectName        = "FDE-Task-B2"
    ProjectOwner       = "ck"
    ProjectDescription = "This is a test project for FDE-Task-B2"
    Application        = "HelloWorld"
    ApplicationOwner   = "Kesav"
    CostCenter         = "FDE-Task-B2"
    ApplicationID      = "FDE-Task-B2"
    Environment        = "Development"
  }
}