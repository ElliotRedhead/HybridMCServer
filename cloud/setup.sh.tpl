#!/bin/bash
set -e

# 1. Wait for cloud-init and unattended-upgrades to release the apt lock (Prevents apt-get lock errors during Docker install)
cloud-init status --wait
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
  echo "Waiting for apt locks to clear..."
  sleep 5
done

# Create a 2GB swap file to prevent OOM crashes on nano_3_0 (1GB RAM)
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
auth.token = "${auth_token}"

[webServer]
addr = "127.0.0.1"
port = 7501
user = "${frp_user}"
password = "${frp_pwd}"
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

sudo docker run -d --name duckdns --restart always --network host -e SUBDOMAINS="${duckdns_domain}" -e TOKEN="${duckdns_token}" lscr.io/linuxserver/duckdns:latest
sleep 3

# 7. Setup Healthcheck Script
sudo tee "/usr/local/bin/healthcheck.sh" << "EOF"
#!/bin/bash
FRP_RES=$(curl -s -u "${frp_user}:${frp_pwd}" "http://127.0.0.1:7501/api/proxy/tcp/minecraft")

if echo "$FRP_RES" | grep -q "\"status\":\"online\""; then
    TUNNEL="online"
    HOST="online"
else
    TUNNEL="offline"
    if ping -c 1 -W 2 "${duckdns_domain}.duckdns.org" >/dev/null 2>&1; then
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
