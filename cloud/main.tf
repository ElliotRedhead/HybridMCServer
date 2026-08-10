provider "aws" {
  region  = "eu-west-2"
  profile = "terraform-lightsail"
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

data "cloudinit_config" "server_setup" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/cloud-config.yaml.tpl", {
      caddyfile_content = templatefile("${path.module}/Caddyfile.tpl", { duckdns_domain = var.duckdns_domain })
      index_content     = templatefile("${path.module}/index.html.tpl", { duckdns_domain = var.duckdns_domain })
    })
  }

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/setup.sh.tpl", {
      auth_token     = var.auth_token
      frp_user       = var.frp_dashboard_creds.user
      frp_pwd        = var.frp_dashboard_creds.pwd
      duckdns_domain = var.duckdns_domain
      duckdns_token  = var.duckdns_token
    })
  }
}

resource "aws_lightsail_instance" "vpn_proxy" {
  name              = "vpn-proxy"
  availability_zone = "eu-west-2b"
  blueprint_id      = "ubuntu_22_04"
  bundle_id         = "nano_3_0"
  key_pair_name     = aws_lightsail_key_pair.vpn_key_pair.name
  user_data         = data.cloudinit_config.server_setup.rendered
}

resource "null_resource" "deploy_modpack" {
  depends_on = [
    aws_lightsail_instance.vpn_proxy,
    aws_lightsail_static_ip_attachment.attach
  ]

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
  count = fileexists("${path.module}/favicon.ico") ? 1 : 0
  depends_on = [aws_lightsail_instance.vpn_proxy]

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
  
  depends_on = [ aws_lightsail_static_ip_attachment.attach ]

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
  }

  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
  }

  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
  }

  port_info {
    protocol  = "tcp"
    from_port = 7000
    to_port   = 7000
  }

  port_info {
    protocol  = "tcp"
    from_port = 7500
    to_port   = 7500
  }

  port_info {
    protocol  = "tcp"
    from_port = 25565
    to_port   = 25565
  }
}

output "public_ip" {
  value = aws_lightsail_static_ip.vpn_static_ip.ip_address
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