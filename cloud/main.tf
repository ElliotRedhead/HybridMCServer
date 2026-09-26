terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

locals {
  caddy_image = "caddy:2.11.4-alpine"
  frps_image  = "snowdreamtech/frps:0.71.0-debian"
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

resource "tls_private_key" "vpn_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_lightsail_key_pair" "vpn_key_pair" {
  name       = "vpn-key-pair"
  public_key = tls_private_key.vpn_key.public_key_openssh
}

resource "local_file" "ssh_key" {
  content         = tls_private_key.vpn_key.private_key_pem
  filename        = "${path.module}/id_rsa.pem"
  file_permission = "0600"
}

resource "aws_lightsail_instance" "vpn_proxy" {
  name              = "vpn-proxy"
  availability_zone = var.availability_zone
  blueprint_id      = "ubuntu_22_04"
  bundle_id         = "nano_3_0"
  key_pair_name     = aws_lightsail_key_pair.vpn_key_pair.name
}

resource "null_resource" "server_setup" {
  depends_on = [
    aws_lightsail_instance.vpn_proxy,
    aws_lightsail_static_ip_attachment.attach,
    aws_lightsail_instance_public_ports.firewall
  ]

  triggers = {
    instance_id = aws_lightsail_instance.vpn_proxy.id
    index_hash  = filemd5("${path.module}/index.html.tpl")
    caddy_hash  = filemd5("${path.module}/Caddyfile.tpl")
    setup_hash  = filemd5("${path.module}/setup.sh.tpl")
    images      = "${local.caddy_image} ${local.frps_image}"
    config_hash = nonsensitive(sha256(jsonencode([var.auth_token, var.frp_dashboard_creds, var.duckdns_domain, var.duckdns_token])))
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_lightsail_static_ip.vpn_static_ip.ip_address
    private_key = tls_private_key.vpn_key.private_key_pem
    timeout     = "5m"
  }

  provisioner "file" {
    content     = templatefile("${path.module}/index.html.tpl", { duckdns_domain = var.duckdns_domain })
    destination = "/home/ubuntu/index.html"
  }

  provisioner "file" {
    content     = templatefile("${path.module}/Caddyfile.tpl", { duckdns_domain = var.duckdns_domain })
    destination = "/home/ubuntu/Caddyfile"
  }

  provisioner "file" {
    content = templatefile("${path.module}/setup.sh.tpl", {
      auth_token     = var.auth_token
      frp_user       = var.frp_dashboard_creds.user
      frp_pwd        = var.frp_dashboard_creds.pwd
      duckdns_domain = var.duckdns_domain
      duckdns_token  = var.duckdns_token
      static_ip      = aws_lightsail_static_ip.vpn_static_ip.ip_address
      caddy_image    = local.caddy_image
      frps_image     = local.frps_image
    })
    destination = "/home/ubuntu/setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "bash /home/ubuntu/setup.sh",
      "rm -f /home/ubuntu/setup.sh"
    ]
  }
}

resource "null_resource" "deploy_modpack" {
  depends_on = [null_resource.server_setup]

  triggers = {
    instance_id = aws_lightsail_instance.vpn_proxy.id
  }

  provisioner "local-exec" {
    command = "make -C ../ cloud-refresh-modpack-version"
  }

  provisioner "local-exec" {
    command = "make -C ../ deploy-modpack"
  }
}

resource "null_resource" "upload_favicon" {
  count      = fileexists("${path.module}/favicon.ico") ? 1 : 0
  depends_on = [null_resource.server_setup]

  triggers = {
    instance_id  = aws_lightsail_instance.vpn_proxy.id
    favicon_hash = fileexists("${path.module}/favicon.ico") ? filemd5("${path.module}/favicon.ico") : ""
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_lightsail_static_ip.vpn_static_ip.ip_address
    private_key = tls_private_key.vpn_key.private_key_pem
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/favicon.ico"
    destination = "/home/ubuntu/favicon.ico"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/ubuntu/favicon.ico /opt/mc-status/favicon.ico",
      "sudo chmod 644 /opt/mc-status/favicon.ico"
    ]
  }
}

resource "aws_lightsail_static_ip" "vpn_static_ip" {
  name = "minecraft-static-ip"
}

resource "aws_lightsail_static_ip_attachment" "attach" {
  static_ip_name = aws_lightsail_static_ip.vpn_static_ip.name
  instance_name  = aws_lightsail_instance.vpn_proxy.name

  lifecycle {
    replace_triggered_by = [
      aws_lightsail_instance.vpn_proxy
    ]
  }
}

resource "aws_lightsail_instance_public_ports" "firewall" {
  instance_name = aws_lightsail_instance.vpn_proxy.name

  depends_on = [aws_lightsail_static_ip_attachment.attach]

  # A rebuilt instance starts with default ports, so re-apply the rules
  lifecycle {
    replace_triggered_by = [
      aws_lightsail_instance.vpn_proxy
    ]
  }

  port_info {
    protocol   = "tcp"
    from_port  = 22
    to_port    = 22
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  port_info {
    protocol   = "tcp"
    from_port  = 80
    to_port    = 80
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  port_info {
    protocol   = "tcp"
    from_port  = 443
    to_port    = 443
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  port_info {
    protocol   = "tcp"
    from_port  = 7000
    to_port    = 7000
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  port_info {
    protocol   = "tcp"
    from_port  = 7500
    to_port    = 7500
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  port_info {
    protocol   = "tcp"
    from_port  = 25565
    to_port    = 25565
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }
}

output "public_ip" {
  value = aws_lightsail_static_ip.vpn_static_ip.ip_address
}

variable "aws_region" {
  description = "AWS region for the Lightsail gateway (pick one close to your players)"
  type        = string
  default     = "eu-west-2"
}

variable "availability_zone" {
  description = "Lightsail availability zone, must be in aws_region"
  type        = string
  default     = "eu-west-2b"
}

variable "aws_profile" {
  description = "AWS CLI profile to use (null uses the default credential chain)"
  type        = string
  default     = null
}

variable "auth_token" {
  type      = string
  sensitive = true
}

variable "duckdns_token" {
  type      = string
  sensitive = true
}

variable "duckdns_domain" {
  type = string
}

variable "frp_dashboard_creds" {
  description = "FRP Dashboard Login"
  type = object({
    user = string
    pwd  = string
  })
  sensitive = true
}

resource "local_file" "home_config" {
  content = templatefile("${path.module}/frpc.tpl", {
    server_addr = aws_lightsail_static_ip.vpn_static_ip.ip_address
    auth_token  = var.auth_token
  })
  filename = "${path.module}/../local/frpc.toml"
  file_permission = "0600"
}

resource "null_resource" "restart_local_frpc" {
  triggers = {
    config_hash = local_file.home_config.id
  }

  provisioner "local-exec" {
    # Sends a restart signal to the local Docker daemon
    command = "docker compose -f ../local/docker-compose.yml restart frpc"
  }
}