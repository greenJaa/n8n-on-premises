#!/bin/bash

# 1. Swap Space (The "Life Support" for t3.micro)
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# 2. Install Docker
apt-get update
apt-get install -y docker.io docker-compose-v2
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

# 3. Setup Directory & Permissions
mkdir -p /home/ubuntu/n8n
# Set ownership now so Docker volumes don't default to root-only if created later
chown -R ubuntu:ubuntu /home/ubuntu/n8n
cd /home/ubuntu/n8n

# 4. Docker Compose
cat <<EOD > docker-compose.yml
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n-server
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 750M
    environment:
      - N8N_PORT=5678
      - DB_TYPE=sqlite
      - WEBHOOK_URL=\${WEBHOOK_URL}
      - N8N_PUSH_BACKEND=websocket
      - N8N_PROXY_HOPS=1
    volumes:
      - ./n8n_data:/home/node/.n8n
  tunnel:
    image: cloudflare/cloudflared:latest
    container_name: n8n-tunnel
    restart: unless-stopped
    command: tunnel --no-autoupdate --url http://n8n:5678 --protocol http2
EOD

# 5. Start Tunnel
# Using --compatibility ensures the 'deploy' memory limits work
docker compose --compatibility up -d tunnel

# 6. URL Discovery Loop
echo "Waiting for Cloudflare URL..."
for i in {1..15}; do
  NEW_URL=$(docker logs n8n-tunnel 2>&1 | grep -o 'https://.*trycloudflare.com' | head -n 1)
  if [ ! -z "$NEW_URL" ]; then
    break
  fi
  sleep 4
done

# 7. Finalize n8n
echo "$NEW_URL" > /home/ubuntu/n8n/url.txt
export WEBHOOK_URL="$NEW_URL"
docker compose --compatibility up -d n8n

# Final permission sweep
chown -R ubuntu:ubuntu /home/ubuntu/n8n