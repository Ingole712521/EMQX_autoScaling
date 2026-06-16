data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  emqx_bootstrap_base = {
    node_cookie              = var.emqx_node_cookie
    dashboard_username       = var.emqx_dashboard_username
    dashboard_password       = var.emqx_dashboard_password
    aws_region               = var.aws_region
    project_name             = var.project_name
    emqx_version             = var.emqx_version
    tune_nofile              = var.emqx_tune_nofile
    tune_max_ports           = var.emqx_tune_max_ports
    tune_acceptors           = var.emqx_tune_acceptors
    tune_max_connections     = var.emqx_tune_max_connections
    tune_dist_buffer_size_kb = var.emqx_tune_dist_buffer_size_kb
    performance_tune_lib     = file("${path.module}/userdata/emqx-performance-tune.sh")
  }
}

resource "aws_instance" "emqx_core" {
  ami                         = data.aws_ami.ubuntu_2204.id
  instance_type               = var.core_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.emqx_nodes_sg.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.emqx_ec2.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/userdata/emqx-bootstrap.sh", merge(local.emqx_bootstrap_base, {
    node_role        = "core"
    core_instance_id = "self"
  }))

  tags = merge(var.tags, {
    Name = "${var.project_name}-core-1"
    Role = "emqx-core"
  })
}

resource "aws_eip" "core_eip" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project_name}-core-eip"
  })
}

resource "aws_eip_association" "core_eip_assoc" {
  instance_id   = aws_instance.emqx_core.id
  allocation_id = aws_eip.core_eip.id
}
