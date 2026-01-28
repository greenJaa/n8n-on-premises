#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

get_output() { terraform output -raw "$1" 2>/dev/null; }
get_ip() { get_output "ec2_public_ip"; }

# Enhanced Health Check
check_health() {
    local ip=$1
    if [ -z "$ip" ]; then echo -e "${RED}OFFLINE (No IP)${NC}"; return; fi
    
    # Check Docker Status + Memory Usage
    # We use 'free -h' to see if the Swap we added is actually being used
    stats=$(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$ip "
        echo '--- Containers ---'
        sudo docker ps --format '{{.Names}}: {{.Status}}'
        echo ''
        echo '--- Memory & Swap ---'
        free -h | grep -E 'Mem|Swap'
    " 2>/dev/null)
    
    if [ -z "$stats" ]; then
        echo -e "${RED}OFFLINE (Server Down or SSH blocked)${NC}"
    else
        echo -e "${GREEN}ONLINE${NC}"
        echo -e "${NC}$stats"
    fi
}

show_url() {
    local ip=$(get_ip)
    [ -z "$ip" ] && { echo -e "${RED}Error: No IP found.${NC}"; return; }
    echo -e "${BLUE}Fetching URL...${NC}"
    URL=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$ip "cat /home/ubuntu/n8n/url.txt 2>/dev/null || sudo docker logs n8n-tunnel 2>&1 | grep -o 'https://.*trycloudflare.com' | head -n 1")
    if [ -z "$URL" ]; then
        echo -e "${YELLOW}URL not ready yet. Try Option 5 if it persists.${NC}"
    else
        echo -e "${GREEN}URL: $URL${NC}"
    fi
}

while true; do
    IP=$(get_ip)
    echo -e "\n${BLUE}=== n8n Manager [${IP:-NO IP}] ===${NC}"
    echo "1) Start Server (Lambda)"
    echo "2) Stop Server (Lambda)"
    echo "3) Get URL"
    echo "4) SSH into Machine"
    echo "5) Refresh Tunnel / Sync URL"
    echo "6) Detailed Health Status"
    echo "7) Exit"
    read -p "Selection: " choice
    case $choice in
        1) curl -s -X POST $(get_output "trigger_start_url") && echo -e "\n${GREEN}Start request sent!${NC}" ;;
        2) curl -s -X POST $(get_output "trigger_stop_url") && echo -e "\n${RED}Stop request sent!${NC}" ;;
        3) show_url ;;
        4) ssh -t -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$IP "cd /home/ubuntu/n8n && bash --login" ;;
        5) 
            echo -e "${BLUE}Refreshing Tunnel...${NC}"
            ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$ip "cd /home/ubuntu/n8n && sudo docker restart n8n-tunnel && sleep 5 && sudo docker logs n8n-tunnel 2>&1 | grep -o 'https://.*trycloudflare.com' | head -n 1 > url.txt"
            show_url
            ;;
        6) echo -e "${BLUE}Checking Health...${NC}"; check_health "$IP" ;;
        7) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
done