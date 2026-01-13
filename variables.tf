variable "aws_region" {
  description = "AWS region"
  default     = "eu-central-1"
}

variable "public_key_path" {
  description = "Path to your public SSH key"
  default     = "~/.ssh/id_rsa.pub"
}

variable "my_ip" {
  description = "Your IP for SSH access"
  default     = "0.0.0.0/0"
}

variable "ami" {
  description = "Ubuntu 22.04 LTS AMI"
  default     = "ami-0c2b8ca1dad447f8a"
}

variable "cron_expression" {
  description = "EventBridge cron for daily n8n run"
  default     = "cron(0 6 * * ? *)" # 6:00 UTC daily
}

