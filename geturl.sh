#!/bin/bash
# Fetch the latest Cloudflare URL from the EC2 instance logs
ssh -i ~/.ssh/id_rsa ubuntu@18.157.76.186 "sudo docker logs n8n-tunnel-1 2>&1 | grep -o 'https://.*trycloudflare.com' | tail -n 1"
