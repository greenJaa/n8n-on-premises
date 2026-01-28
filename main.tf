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

# --- 1. Infrastructure ---
resource "aws_vpc" "n8n_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "n8n-vpc" }
}

resource "aws_internet_gateway" "n8n_igw" {
  vpc_id = aws_vpc.n8n_vpc.id
}

resource "aws_subnet" "n8n_subnet" {
  vpc_id                  = aws_vpc.n8n_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_route_table" "n8n_rt" {
  vpc_id = aws_vpc.n8n_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.n8n_igw.id
  }
}

resource "aws_route_table_association" "n8n_rta" {
  subnet_id      = aws_subnet.n8n_subnet.id
  route_table_id = aws_route_table.n8n_rt.id
}

# --- 2. Security & EC2 ---
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "n8n_key" {
  key_name   = "n8n-key"
  public_key = file(var.public_key_path)
}

resource "aws_security_group" "n8n_sg" {
  name        = "n8n-sg"
  description = "Allow SSH and n8n ports"
  vpc_id      = aws_vpc.n8n_vpc.id

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

resource "aws_instance" "n8n" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.n8n_key.key_name
  vpc_security_group_ids = [aws_security_group.n8n_sg.id]
  subnet_id              = aws_subnet.n8n_subnet.id

  user_data = file("${path.module}/setup.sh")

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }
  
  tags = { Name = "n8n-server" }
}

# --- 3. IAM & Lambda ---
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
        Action   = ["ec2:StartInstances", "ec2:StopInstances", "ec2:DescribeInstances"]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

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
    variables = { INSTANCE_ID = aws_instance.n8n.id }
  }
}

resource "aws_lambda_function" "stop_ec2" {
  function_name = "stop-n8n-ec2"
  role          = aws_iam_role.lambda_ec2_role.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  filename      = data.archive_file.stop_lambda.output_path
  environment {
    variables = { INSTANCE_ID = aws_instance.n8n.id }
  }
}

# --- 4. API Gateway (Fixed Resources) ---
resource "aws_api_gateway_rest_api" "n8n_trigger" {
  name = "n8n-trigger-api"
}

# Start Resource
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

# Stop Resource
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

# Deployment and Stage (Fixing Deprecation and Cycles)
resource "aws_api_gateway_deployment" "n8n_deploy" {
  depends_on = [
    aws_api_gateway_integration.start_post_lambda,
    aws_api_gateway_integration.stop_post_lambda
  ]
  rest_api_id = aws_api_gateway_rest_api.n8n_trigger.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.start.id,
      aws_api_gateway_method.start_post.id,
      aws_api_gateway_resource.stop.id,
      aws_api_gateway_method.stop_post.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.n8n_deploy.id
  rest_api_id   = aws_api_gateway_rest_api.n8n_trigger.id
  stage_name    = "prod"
}

# --- 5. Permissions ---
resource "aws_lambda_permission" "apigw_start" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_ec2.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.n8n_trigger.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_stop" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stop_ec2.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.n8n_trigger.execution_arn}/*/*"
}

