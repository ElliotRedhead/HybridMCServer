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

resource "aws_lightsail_instance" "vpn_proxy" {
  name              = "vpn-proxy"
  availability_zone = "eu-west-2b"
  blueprint_id      = "ubuntu_22_04"
  bundle_id         = "nano_2_0"
  key_pair_name     = aws_lightsail_key_pair.vpn_key_pair.name

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = self.public_ip_address
    private_key = tls_private_key.vpn_key.private_key_pem
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Checking for swap...'",
      "if [ ! -f /swapfile ]; then",
      "  echo 'Creating 1GB Swapfile...'",
      "  sudo fallocate -l 1G /swapfile",
      "  sudo chmod 600 /swapfile",
      "  sudo mkswap /swapfile",
      "  sudo swapon /swapfile",
      "  # Make it permanent",
      "  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab",
      "  # Tell Linux to use swap only when necessary",
      "  echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf",
      "  sudo sysctl -p",
      "fi",

      "sudo systemctl stop unattended-upgrades",
      "sudo killall apt apt-get 2>/dev/null || true",

      "if ! command -v docker &> /dev/null; then",
      "  curl -fsSL https://get.docker.com -o get-docker.sh",
      "  sudo sh get-docker.sh",
      "  sudo usermod -aG docker ubuntu",
      "fi",

      # CONFIGURE FRP (with dashboard for monitoring) ---
      "sudo mkdir -p /etc/frp",
      "printf 'bindPort = 7000\n\nauth.method = \"token\"\nauth.token = \"%s\"\n\n[webServer]\naddr = \"0.0.0.0\"\nport = 7500\nuser = \"%s\"\npassword = \"%s\"\n' '${var.auth_token}' '${var.frp_dashboard_creds.user}' '${var.frp_dashboard_creds.pwd}' | sudo tee /etc/frp/frps.toml",

      # Stop existing containers to force config reload on restart
      "sudo docker rm -f frps duckdns 2>/dev/null || true",
      "sudo docker run -d --name frps --restart always --network host -v /etc/frp/frps.toml:/etc/frp/frps.toml snowdreamtech/frps",
      
      "sudo docker run -d --name duckdns --restart always --network host -e SUBDOMAINS=${var.duckdns_domain} -e TOKEN=${var.duckdns_token} lscr.io/linuxserver/duckdns:latest"
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
    from_port = 7000
    to_port   = 7000
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