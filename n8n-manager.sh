#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

get_ip() {
    terraform output -raw ec2_public_ip 2>/dev/null
}

show_health() {
    local ip=$(get_ip)
    if [ -z "$ip" ] || [[ "$ip" == *"No outputs"* ]]; then echo -e "${RED}No IP found.${NC}"; return; fi
    echo -e "${BLUE}Checking RAM and Disk on $ip...${NC}"
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$ip "echo '--- MEMORY ---' && free -h && echo '' && echo '--- DISK ---' && df -h /"
}

show_url() {
    local ip=$(get_ip)
    if [ -z "$ip" ] || [[ "$ip" == *"No outputs"* ]]; then echo -e "${RED}No IP found.${NC}"; return; fi
    echo -e "${BLUE}Fetching URL from $ip...${NC}"
    URL=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$ip "sudo docker logs --tail 50 n8n-tunnel-1 2>&1 | grep 'https://' | grep 'trycloudflare.com' | grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' | tail -n 1")
    if [ -z "$URL" ]; then
        echo -e "${RED}URL not found yet. Wait 30s and try again.${NC}"
    else
        echo -e "${GREEN}URL: $URL${NC}"
    fi
}

start_server() {
    local trigger=$(terraform output -raw trigger_url)
    echo -e "${BLUE}Starting via API...${NC}"
    until curl -s -X POST "$trigger" | grep -qE "starting|running"; do 
        echo "Waiting for start signal..."
        sleep 5
    done
    echo -e "${GREEN}Started! Waiting 45s for services...${NC}"
    sleep 45 && show_url
}

stop_server() {
    local stop=$(terraform output -raw stop_url)
    curl -s -X POST "$stop"
    echo -e "${RED}Stop signal sent.${NC}"
}

while true; do
    IP=$(get_ip)
    echo -e "\n${BLUE}=== n8n Manager [$IP] ===${NC}"
    echo "1) Start Server"
    echo "2) Stop Server"
    echo "3) Get URL"
    echo "4) Check Health (RAM/Disk)"
    echo "5) Exit"
    read -p "Selection: " choice
    case $choice in
        1) start_server ;;
        2) stop_server ;;
        3) show_url ;;
        4) show_health ;;
        5) exit 0 ;;
        *) echo "Invalid choice." ;;
    esac
done
