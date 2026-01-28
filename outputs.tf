output "ec2_public_ip" {
  value = aws_instance.n8n.public_ip
}

output "n8n_url_checker" {
  value = "ssh -i your-key ubuntu@${aws_instance.n8n.public_ip} 'cat /home/ubuntu/n8n/url.txt'"
}

output "trigger_start_url" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/start"
}

output "trigger_stop_url" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/stop"
}
