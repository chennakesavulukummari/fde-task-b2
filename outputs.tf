output "instance_id" {
  value = aws_instance.example.id
}

output "instance_public_ip" {
  value = aws_instance.example.public_ip
}

output "instance_private_ip" {
  value = aws_instance.example.private_ip
}

output "instance_ami" {
  value = aws_instance.example.ami
}

output "instance_type" {
  value = aws_instance.example.instance_type
}

output "instance_key_name" {
  value = aws_instance.example.key_name
}
