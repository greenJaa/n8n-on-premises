terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- Data Sources ---

# 1. FIXED: Added the Default VPC lookup to prevent the 400 error
data "aws_vpc" "default" {
  default = true
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- EC2 Key Pair ---
resource "aws_key_pair" "n8n_key" {
  key_name   = "n8n-key"
  public_key = file(var.public_key_path)
}

# --- Security Group ---
resource "aws_security_group" "n8n_sg" {
  name        = "n8n-sg"
  description = "Allow SSH and n8n ports"
  vpc_id      = data.aws_vpc.default.id # 2. FIXED: Link SG to the VPC

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  ingress {
    from_port   = 5678
    to_port     = 5678
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- EC2 Instance ---
resource "aws_instance" "n8n" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.n8n_key.key_name
  vpc_security_group_ids = [aws_security_group.n8n_sg.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              sudo growpart /dev/nvme0n1 1 || sudo growpart /dev/xvda 1
              sudo resize2fs /dev/nvme0n1p1 || sudo resize2fs /dev/xvda1

              if [ ! -f /swapfile ]; then
                sudo fallocate -l 2G /swapfile
                sudo chmod 600 /swapfile
                sudo mkswap /swapfile
                sudo swapon /swapfile
                echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
              fi

              sudo apt-get update
              sudo apt-get install -y docker.io docker-compose-v2
              
              mkdir -p /home/ubuntu/n8n/n8n_data
              sudo chown -R 1000:1000 /home/ubuntu/n8n/n8n_data
              cd /home/ubuntu/n8n

              cat <<EOD > docker-compose.yml
              services:
                n8n:
                  image: n8nio/n8n:latest
                  restart: unless-stopped
                  environment:
                    - N8N_PORT=5678
                    - DB_TYPE=sqlite
                    - WEBHOOK_URL=\$${DYNAMIC_URL}
                    - NODES_EXCLUDE=[]
                    - N8N_PUSH_BACKEND=sse
                  volumes:
                    - ./n8n_data:/home/node/.n8n
                
                tunnel:
                  image: cloudflare/cloudflared:latest
                  restart: unless-stopped
                  command: tunnel --no-autoupdate --url http://n8n:5678
              EOD

              sudo docker compose up -d tunnel
              sleep 20
              NEW_URL=$(sudo docker logs n8n-tunnel-1 2>&1 | grep -o 'https://.*trycloudflare.com' | head -n 1)
              echo \$NEW_URL > /home/ubuntu/n8n/url.txt
              DYNAMIC_URL=\$NEW_URL sudo -E docker compose up -d n8n
            EOF

  tags = { Name = "n8n-server" }
} # 3. FIXED: Closing brace for aws_instance was properly added

# ... [The rest of your IAM, Lambda, API Gateway, and Output code remains correct] ...