#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

get_ip() { terraform output -raw ec2_public_ip 2>/dev/null; }

reset_n8n() {
    local ip=$(get_ip)
    echo -e "${RED}WARNING: This will delete ALL workflows and reset your password!${NC}"
    read -p "Are you sure? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        ssh -i ~/.ssh/id_rsa ubuntu@$ip "sudo docker stop n8n-n8n-1 && sudo rm -rf /home/ubuntu/n8n/n8n_data/* && sudo docker start n8n-n8n-1"
        echo -e "${GREEN}n8n has been reset. Use Option 5 to get a fresh URL.${NC}"
    fi
}

show_url() {
    local ip=$(get_ip)
    echo -e "${BLUE}Fetching current URL...${NC}"
    URL=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$ip "sudo docker logs --tail 50 n8n-tunnel-1 2>&1 | grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' | tail -n 1")
    echo -e "${GREEN}URL: $URL${NC}"
}

refresh_url() {
    local ip=$(get_ip)
    echo -e "${BLUE}Restarting Tunnel for new URL...${NC}"
    ssh -i ~/.ssh/id_rsa ubuntu@$ip "sudo docker restart n8n-tunnel-1"
    sleep 15 && show_url
}

while true; do
    IP=$(get_ip)
    echo -e "\n${BLUE}=== n8n Manager [$IP] ===${NC}"
    echo "1) Start Server"
    echo "2) Stop Server"
    echo "3) Get URL"
    echo "4) Check Health (RAM/Disk)"
    echo "5) Refresh Tunnel (New URL)"
    echo "6) RESET n8n (Forgot Password)"
    echo "7) Exit"
    read -p "Selection: " choice
    case $choice in
        1) curl -s -X POST $(terraform output -raw trigger_url) ;;
        2) curl -s -X POST $(terraform output -raw stop_url) ;;
        3) show_url ;;
        4) ssh -i ~/.ssh/id_rsa ubuntu@$IP "free -h && df -h /" ;;
        5) refresh_url ;;
        6) reset_n8n ;;
        7) exit 0 ;;
    esac
done
