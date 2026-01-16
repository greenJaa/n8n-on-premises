#!/bin/bash
echo "Sending stop command to EC2..."
RESPONSE=$(curl -s -X POST $(terraform output -raw stop_url))
if [[ $RESPONSE == *"stopping"* ]]; then
  echo "Success: EC2 is now shutting down."
else
  echo "Error: $RESPONSE"
fi
