output "public_ip" {
  description = "Static public IP of the server."
  value       = aws_eip.this.public_ip
}

output "ssh_command" {
  description = "SSH into the server (wait 2-3 minutes after apply for cloud-init to finish)."
  value       = "ssh ${var.deploy_user}@${aws_eip.this.public_ip}"
}

output "sslip_domain" {
  description = "Free wildcard DNS name you can use as DOMAIN if you don't own a domain."
  value       = "${replace(aws_eip.this.public_ip, ".", "-")}.sslip.io"
}
