resource "aws_lightsail_key_pair" "public_gateway_key_pair" {
  name = "aether-public-gateway-key-pair"
}

resource "local_file" "public_gateway_private_key" {
  content         = aws_lightsail_key_pair.public_gateway_key_pair.private_key
  filename        = "../secrets/public_gateway_private_key.pem"
  file_permission = "0600"
}

resource "aws_lightsail_instance" "public_gateway" {
  name              = "aether-public-gateway"
  availability_zone = "us-east-1b"
  blueprint_id      = "amazon_linux_2023"
  bundle_id         = "nano_3_0"
  key_pair_name     = aws_lightsail_key_pair.public_gateway_key_pair.id
}

resource "aws_lightsail_instance_public_ports" "public_gateway_public_ports" {
  instance_name = aws_lightsail_instance.public_gateway.id

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
  }

  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
  }
}

resource "aws_lightsail_static_ip" "public_gateway_static_ip" {
  name = "aether-public-gateway-static-ip"
}

resource "aws_lightsail_static_ip_attachment" "public_gateway_static_ip_attachment" {
  static_ip_name = aws_lightsail_static_ip.public_gateway_static_ip.id
  instance_name  = aws_lightsail_instance.public_gateway.id
}

output "public_gateway_ip" {
  value = aws_lightsail_static_ip.public_gateway_static_ip.ip_address
}

output "public_gateway_public_key" {
  value = aws_lightsail_key_pair.public_gateway_key_pair.public_key
}

output "public_gateway_private_key" {
  value     = aws_lightsail_key_pair.public_gateway_key_pair.private_key
  sensitive = true
}

output "public_gateway_private_key_path" {
  value = local_file.public_gateway_private_key.filename
}
