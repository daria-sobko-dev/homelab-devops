locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# Latest official Ubuntu 24.04 LTS image from Canonical.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "this" {
  key_name   = "${var.project_name}-key"
  public_key = local.ssh_public_key
}

# --- Firewall (security group) ------------------------------------------------
# Only the ports that are actually needed are open. Everything else
# (Prometheus, exporters, container ports) stays on internal Docker networks.

resource "aws_security_group" "this" {
  name        = "${var.project_name}-sg"
  description = "Homelab: SSH, HTTP/HTTPS and WireGuard"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "SSH"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.this.id
  description       = "HTTP (Let's Encrypt challenge + redirect to HTTPS)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "wireguard" {
  security_group_id = aws_security_group.this.id
  description       = "WireGuard VPN"
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51820
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Server -------------------------------------------------------------------

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.this.id]

  # cloud-init runs scripts/bootstrap.sh on first boot (Docker, firewall, SSH hardening, swap).
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    deploy_user      = var.deploy_user
    ssh_public_key   = local.ssh_public_key
    bootstrap_script = file("${path.module}/../scripts/bootstrap.sh")
  })
  user_data_replace_on_change = true

  # Require IMDSv2 tokens (protects instance credentials from SSRF attacks).
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  # T3 instances default to "unlimited" CPU credits, which can be billed extra.
  credit_specification {
    cpu_credits = "standard"
  }

  tags = {
    Name = var.project_name
  }

  lifecycle {
    # Don't recreate the server every time Canonical publishes a new AMI.
    ignore_changes = [ami]
  }
}

# Static public IP, so DNS records survive instance stop/start.
resource "aws_eip" "this" {
  instance = aws_instance.this.id
  domain   = "vpc"
}
