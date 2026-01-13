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

# --- Data Source: Latest Ubuntu 22.04 AMI ---
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

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    # Change this temporarily to allow connection from anywhere
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

user_data = <<-EOF
              #!/bin/bash
              # 1. Update and install Docker + Compose Plugin
              sudo apt-get update
              sudo apt-get install -y docker.io docker-compose-v2
              
              # 2. Ensure Docker starts on boot
              sudo systemctl enable docker
              sudo systemctl start docker
              
              # 3. Setup n8n directory with correct permissions
              mkdir -p /home/ubuntu/n8n/n8n_data
              # Crucial: Give ownership to the 'node' user (UID 1000) used by n8n container
              sudo chown -R 1000:1000 /home/ubuntu/n8n/n8n_data
              
              cd /home/ubuntu/n8n
              
              # 4. Create the config
              cat <<EOD > docker-compose.yml
              version: "3.8"
              services:
                n8n:
                  image: n8nio/n8n:latest
                  restart: unless-stopped
                  ports:
                    - "5678:5678"
                  environment:
                    - N8N_PORT=5678
                    - GENERIC_TIMEZONE=UTC
                    - DB_TYPE=sqlite
                    - N8N_SECURE_COOKIE=false
                  volumes:
                    - ./n8n_data:/home/node/.n8n
              EOD
              
              # 5. Start n8n
              sudo docker compose up -d
              EOF
  tags = {
    Name = "n8n-server"
  }
}
# --- IAM Role for Lambda ---
resource "aws_iam_role" "lambda_ec2_role" {
  name = "lambda-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_ec2_policy" {
  name = "lambda-ec2-policy"
  role = aws_iam_role.lambda_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:DescribeInstances"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# --- Lambda Functions ---
data "archive_file" "start_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/start"
  output_path = "${path.module}/lambda/start.zip"
}

data "archive_file" "stop_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/stop"
  output_path = "${path.module}/lambda/stop.zip"
}

resource "aws_lambda_function" "start_ec2" {
  function_name = "start-n8n-ec2"
  role          = aws_iam_role.lambda_ec2_role.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  filename      = data.archive_file.start_lambda.output_path

  environment {
    variables = {
      INSTANCE_ID = aws_instance.n8n.id
    }
  }
}

resource "aws_lambda_function" "stop_ec2" {
  function_name = "stop-n8n-ec2"
  role          = aws_iam_role.lambda_ec2_role.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  filename      = data.archive_file.stop_lambda.output_path

  environment {
    variables = {
      INSTANCE_ID = aws_instance.n8n.id
    }
  }
}

# --- EventBridge Scheduled Rule ---
resource "aws_cloudwatch_event_rule" "daily_n8n" {
  name                = "daily-n8n-run"
  schedule_expression = var.cron_expression
}

resource "aws_cloudwatch_event_target" "daily_lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_n8n.name
  target_id = "start-n8n"
  arn       = aws_lambda_function.start_ec2.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_ec2.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_n8n.arn
}

# --- API Gateway ---
resource "aws_api_gateway_rest_api" "n8n_trigger" {
  name = "n8n-trigger-api"
}

# START Endpoint
resource "aws_api_gateway_resource" "start" {
  rest_api_id = aws_api_gateway_rest_api.n8n_trigger.id
  parent_id   = aws_api_gateway_rest_api.n8n_trigger.root_resource_id
  path_part   = "start"
}

resource "aws_api_gateway_method" "start_post" {
  rest_api_id   = aws_api_gateway_rest_api.n8n_trigger.id
  resource_id   = aws_api_gateway_resource.start.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "start_post_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.n8n_trigger.id
  resource_id             = aws_api_gateway_resource.start.id
  http_method             = aws_api_gateway_method.start_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.start_ec2.invoke_arn
}

# STOP Endpoint
resource "aws_api_gateway_resource" "stop" {
  rest_api_id = aws_api_gateway_rest_api.n8n_trigger.id
  parent_id   = aws_api_gateway_rest_api.n8n_trigger.root_resource_id
  path_part   = "stop"
}

resource "aws_api_gateway_method" "stop_post" {
  rest_api_id   = aws_api_gateway_rest_api.n8n_trigger.id
  resource_id   = aws_api_gateway_resource.stop.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "stop_post_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.n8n_trigger.id
  resource_id             = aws_api_gateway_resource.stop.id
  http_method             = aws_api_gateway_method.stop_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.stop_ec2.invoke_arn
}

# --- Deployment and Stage ---
# --- Deployment and Stage ---
resource "aws_api_gateway_deployment" "n8n_deploy" {
  # This triggers a new deployment whenever the API structure changes
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.start.id,
      aws_api_gateway_method.start_post.id,
      aws_api_gateway_integration.start_post_lambda.id,
      aws_api_gateway_resource.stop.id,
      aws_api_gateway_method.stop_post.id,
      aws_api_gateway_integration.stop_post_lambda.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on  = [
    aws_api_gateway_integration.start_post_lambda, 
    aws_api_gateway_integration.stop_post_lambda
  ]
  rest_api_id = aws_api_gateway_rest_api.n8n_trigger.id
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.n8n_deploy.id
  rest_api_id   = aws_api_gateway_rest_api.n8n_trigger.id
  stage_name    = "prod"
}

# --- Permissions ---
resource "aws_lambda_permission" "apigw_start_lambda" {
  statement_id  = "AllowStartExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_ec2.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.n8n_trigger.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_stop_lambda" {
  statement_id  = "AllowStopExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stop_ec2.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.n8n_trigger.execution_arn}/*/*"
}

# --- Final Outputs ---

# The actual IP of your server
output "ec2_public_ip" {
  value = aws_instance.n8n.public_ip
}

# The direct link to your n8n interface
output "n8n_url" {
  value = "http://${aws_instance.n8n.public_ip}:5678"
}

output "trigger_url" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/start"
}

output "stop_url" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/stop"
}