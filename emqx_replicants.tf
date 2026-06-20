resource "aws_lb" "mqtt_nlb" {
  name               = "${var.project_name}-mqtt-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.nlb_sg.id]

  enable_cross_zone_load_balancing = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-mqtt-nlb"
  })
}

resource "aws_lb_target_group" "mqtt_tg" {
  name        = "${var.project_name}-mqtt-tg"
  port        = 1883
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  deregistration_delay = 10

  health_check {
    protocol            = "TCP"
    port                = "1883"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 10
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-mqtt-tg"
  })
}

resource "aws_lb_listener" "mqtt_1883" {
  load_balancer_arn = aws_lb.mqtt_nlb.arn
  port              = 1883
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mqtt_tg.arn
  }
}

resource "aws_launch_template" "emqx_replicant_lt" {
  name_prefix   = "${var.project_name}-replicant-"
  image_id      = data.aws_ami.ubuntu_2204.id
  instance_type = var.replicant_instance_type
  key_name      = var.key_name

  monitoring {
    enabled = true
  }

  vpc_security_group_ids = [aws_security_group.emqx_nodes_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.emqx_ec2.name
  }

  update_default_version = true

  user_data = base64gzip(templatefile("${path.module}/userdata/emqx-bootstrap.sh", merge(local.emqx_bootstrap_base, {
    node_role           = "replicant"
    core_instance_id    = aws_instance.emqx_core.id
    lifecycle_hook_name = "${var.project_name}-replicant-terminate"
    asg_name            = "${var.project_name}-replicants-asg"
  })))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.project_name}-replicant"
      Role = "emqx-replicant"
    })
  }
}

resource "aws_autoscaling_group" "emqx_replicants_asg" {
  name                      = "${var.project_name}-replicants-asg"
  vpc_zone_identifier       = aws_subnet.public[*].id
  min_size                  = var.replicant_min_size
  max_size                  = var.replicant_max_size
  desired_capacity          = var.replicant_desired_capacity
  health_check_type         = "ELB"
  health_check_grace_period = 600

  launch_template {
    id      = aws_launch_template.emqx_replicant_lt.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.mqtt_tg.arn]

  tag {
    key                 = "Name"
    value               = "${var.project_name}-replicant"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  depends_on = [
    aws_instance.emqx_core,
    aws_ssm_parameter.core_private_ip,
    aws_ssm_parameter.cluster_seeds,
  ]

  lifecycle {
    create_before_destroy = true
    # Let CloudWatch autoscaling policies raise desired_capacity above terraform's initial value.
    ignore_changes = [desired_capacity]
  }

  default_cooldown = var.autoscaling_cooldown_sec

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 600
    }
  }
}
