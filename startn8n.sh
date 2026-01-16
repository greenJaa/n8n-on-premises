#!/bin/bash
echo "Checking instance status..."
# Loop until the start command is accepted
until curl -s -X POST $(terraform output -raw trigger_url) | grep -q "starting"; do
  echo "Instance is still busy (stopping or pending). Waiting 5 seconds..."
  sleep 5
done

echo "Instance is starting. Waiting for Cloudflare Tunnel (approx 45s)..."
sleep 45
./geturl.sh
