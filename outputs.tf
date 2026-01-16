output "n8n_url_checker" {
  # Change 'your_instance' to 'n8n' (or whatever name is in your main.tf)
  value = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_instance.n8n.public_ip} 'cat /home/ubuntu/n8n/url.txt'"
  description = "Run this command 1 minute after apply to see your Cloudflare URL"
}