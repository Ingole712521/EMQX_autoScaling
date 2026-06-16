data "aws_ami" "ubuntu" {
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

resource "aws_launch_template" "this" {
  name_prefix   = "${var.project_name}-replicant-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_name

  monitoring {
    enabled = true
  }

  vpc_security_group_ids = [var.replicant_sg_id]

  iam_instance_profile {
    name = var.instance_profile_name
  }

  update_default_version = true

  user_data = base64encode(templatefile(var.replicant_userdata_template_path, {
    node_cookie                = var.node_cookie
    dashboard_username         = var.dashboard_username
    dashboard_password         = var.dashboard_password
    seed_nodes                 = jsonencode(var.core_seed_hosts)
    tune_nofile                = var.emqx_tune_nofile
    tune_max_ports             = var.emqx_tune_max_ports
    tune_acceptors             = var.emqx_tune_acceptors
    tune_max_connections       = var.emqx_tune_max_connections
    tune_dist_buffer_size_kb   = var.emqx_tune_dist_buffer_size_kb
    performance_tune_lib       = file("${path.root}/../userdata/emqx-performance-tune.sh")
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.project_name}-replicant"
      Role = "emqx-replicant"
    })
  }
}

resource "aws_autoscaling_group" "this" {
  name                      = "${var.project_name}-replicants-asg"
  vpc_zone_identifier       = var.private_subnet_ids
  min_size                  = var.min_size
  desired_capacity          = var.desired_capacity
  max_size                  = var.max_size
  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_period
  target_group_arns         = var.target_group_arns
  default_cooldown          = var.default_cooldown_sec

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-replicant"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = var.health_check_grace_period
    }
  }
}
