#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

get_ip() {
    terraform output -raw ec2_public_ip 2>/dev/null
}

wait_for_ssh() {
    local ip=$1
    echo -e "${BLUE}Waiting for SSH to wake up on $ip...${NC}"
    # Try to connect every 5 seconds until successful
    while ! nc -z -w 5 "$ip" 22; do
        echo "..."
        sleep 5
    done
    echo -e "${GREEN}SSH is alive!${NC}"
}

show_url() {
    local ip=$(get_ip)
    if [ -z "$ip" ]; then echo -e "${RED}No IP found.${NC}"; return; fi
    
    wait_for_ssh "$ip"
    
    echo -e "${BLUE}Fetching n8n Tunnel URL...${NC}"
    # Pull the URL from docker logs
    URL=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@"$ip" "sudo docker logs n8n-tunnel-1 2>&1 | grep -o 'https://.*trycloudflare.com' | tail -n 1")
    
    if [ -z "$URL" ]; then
        echo -e "${RED}Tunnel URL not found yet. It may take another 30s for the container to start.${NC}"
    else
        echo -e "${GREEN}SUCCESS! Your n8n URL is: $URL${NC}"
    fi
}

start_server() {
    local trigger=$(terraform output -raw trigger_url)
    echo -e "${BLUE}Starting n8n Server via API...${NC}"
    
    until curl -s -X POST "$trigger" | grep -q "starting"; do
        echo "Instance busy (stopping/pending). Waiting..."
        sleep 5
    done
    
    echo -e "${GREEN}Start command accepted.${NC}"
    # Wait for the system to boot
    show_url
}

stop_server() {
    local stop=$(terraform output -raw stop_url)
    echo -e "${RED}Stopping n8n Server...${NC}"
    curl -s -X POST "$stop"
    echo -e "${GREEN}Stop signal sent successfully.${NC}"
}

# --- Main Menu ---
while true; do
    IP=$(get_ip)
    echo -e "\n${BLUE}=== Dynamic n8n Manager [$IP] ===${NC}"
    echo "1) Start n8n Server"
    echo "2) Stop n8n Server"
    echo "3) Refresh/Get URL"
    echo "4) Exit"
    read -p "Selection: " choice

    case $choice in
        1) start_server ;;
        2) stop_server ;;
        3) show_url ;;
        4) exit 0 ;;
        *) echo "Invalid choice." ;;
    esac
done
