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

# ... (Keep steps 1 through 5 the same) ...

# 6. URL Discovery Loop (The "Patience" Patch)
echo "Waiting for the Secret Map (Cloudflare URL)..."
# We increased this from 15 to 40 so the 'Small Pony' server has time to finish
for i in {1..40}; do
  # This command looks inside the tunnel's diary to find the new link
  NEW_URL=$(docker logs n8n-tunnel 2>&1 | grep -o 'https://.*trycloudflare.com' | head -n 1)
  
  if [ ! -z "$NEW_URL" ]; then
    echo "Found it! The Castle is at: $NEW_URL"
    break
  fi
  echo "Still looking... (Try $i of 40)"
  sleep 4
done

# 7. Finalize n8n (The "Marker" Step)
if [ ! -z "$NEW_URL" ]; then
  echo "$NEW_URL" > /home/ubuntu/n8n/url.txt
  export WEBHOOK_URL="$NEW_URL"
  # Now we start the n8n brain with the right map!
  docker compose --compatibility up -d n8n
else
  echo "Oh no! The Robot couldn't find the URL in time. Try running Option 5 again."
fi

# Final permission sweep
chown -R ubuntu:ubuntu /home/ubuntu/n8n