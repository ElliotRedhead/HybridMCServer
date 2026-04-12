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
}

resource "null_resource" "server_setup" {
  depends_on = [
    aws_lightsail_instance.vpn_proxy,
    aws_lightsail_static_ip_attachment.attach,
    aws_lightsail_instance_public_ports.firewall
  ]

  triggers = {
    instance_id = aws_lightsail_instance.vpn_proxy.id
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

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -e

      # 1. Wait for cloud-init (Prevents apt-get lock errors)
      cloud-init status --wait

	  # Create a 2GB swap file to prevent OOM crashes on nano_2_0 (512MB RAM)
      if [ ! -f "/swapfile" ]; then
        sudo dd if="/dev/zero" of="/swapfile" bs=1M count=2048 status=progress
        sudo chmod 600 "/swapfile"
        sudo mkswap "/swapfile"
        sudo swapon "/swapfile"
        echo "/swapfile swap swap defaults 0 0" | sudo tee -a "/etc/fstab"
      fi

      # 2. Install Docker if missing
      if ! command -v docker > /dev/null 2>&1; then
        curl -fsSL "https://get.docker.com" -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker ubuntu
      fi

      # 3. Create Directories
      sudo mkdir -p /etc/frp /opt/mc-status /opt/caddy/data /opt/caddy/config

      # 4. Write FRPS Config
      sudo tee /etc/frp/frps.toml << "EOF"
      bindPort = 7000
      auth.method = "token"
      auth.token = "${var.auth_token}"

      [webServer]
      addr = "127.0.0.1"
      port = 7501
      user = "${var.frp_dashboard_creds.user}"
      password = "${var.frp_dashboard_creds.pwd}"
EOF

      # 5. Move UI files
      [ -f "/home/ubuntu/index.html" ] && sudo mv "/home/ubuntu/index.html" "/opt/mc-status/index.html"
      [ -f "/home/ubuntu/Caddyfile" ] && sudo mv "/home/ubuntu/Caddyfile" "/opt/caddy/Caddyfile"

      # 6. Start Containers
      sudo docker rm -f status-web frps duckdns 2>/dev/null || true
      
      sudo docker run -d --name status-web --restart always --network host \
        -v "/opt/mc-status:/usr/share/caddy:ro" \
        -v "/opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
        -v "/opt/caddy/data:/data" \
        -v "/opt/caddy/config:/config" \
        caddy:alpine
      sleep 3

      sudo docker run -d --name frps --restart always --network host -v "/etc/frp/frps.toml:/etc/frp/frps.toml" snowdreamtech/frps
      sleep 3

      sudo docker run -d --name duckdns --restart always --network host -e SUBDOMAINS="${var.duckdns_domain}" -e TOKEN="${var.duckdns_token}" lscr.io/linuxserver/duckdns:latest
      sleep 3

      # 7. Setup Healthcheck Script
      sudo tee "/usr/local/bin/healthcheck.sh" << "EOF"
#!/bin/bash
FRP_RES=$(curl -s -u "${var.frp_dashboard_creds.user}:${var.frp_dashboard_creds.pwd}" "http://127.0.0.1:7501/api/proxy/tcp/minecraft")

if echo "$FRP_RES" | grep -q "\"status\":\"online\""; then
    TUNNEL="online"
    HOST="online"
else
    TUNNEL="offline"
    if ping -c 1 -W 2 "${var.duckdns_domain}.duckdns.org" >/dev/null 2>&1; then
        HOST="online"
    else
        HOST="offline"
    fi
fi

echo "{\"host\": \"$HOST\", \"tunnel\": \"$TUNNEL\"}" > "/opt/mc-status/health.json"
chmod 644 "/opt/mc-status/health.json"
EOF

      sudo chmod +x "/usr/local/bin/healthcheck.sh"
      echo "* * * * * root /usr/local/bin/healthcheck.sh" | sudo tee "/etc/cron.d/mc-healthcheck"
      sudo systemctl restart cron
      sudo "/usr/local/bin/healthcheck.sh"
      EOT
    ]
  }

  # 8. Push Local Modpack Version to Cloud
  provisioner "local-exec" {
    command = "make -C ../ cloud-refresh-modpack-version"
  }

  # 9. Build and deploy modpack.zip to cloud
  provisioner "local-exec" {
    command = "make -C ../ deploy-modpack"
  }
}

resource "null_resource" "upload_favicon" {
  count = fileexists("${path.module}/favicon.ico") ? 1 : 0
  depends_on = [null_resource.server_setup]

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