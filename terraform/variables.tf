variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "homelab"
}

variable "instance_type" {
  description = "EC2 instance type. The full stack needs ~1.5 GB RAM, so t3.small (2 GB) is the practical minimum."
  type        = string
  default     = "t3.small"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 20
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key that will be allowed to log in as the deploy user."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "deploy_user" {
  description = "Non-root user created on the server for administration and CI deploys."
  type        = string
  default     = "deploy"
}

variable "ssh_allowed_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach SSH (22/tcp).
    GitHub-hosted runners use changing IPs, so CI deploys need 0.0.0.0/0.
    Password login is disabled and fail2ban is enabled, so only key-based access works.
    If you deploy manually or via a self-hosted runner, restrict this to your own IP (x.x.x.x/32).
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.ssh_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry must be a valid CIDR block, e.g. 203.0.113.10/32."
  }
}
