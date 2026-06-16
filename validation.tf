# Validation infrastructure: ASG lifecycle hook (graceful drain) + optional load-generator EC2.

resource "aws_autoscaling_lifecycle_hook" "replicant_terminate" {
  name                   = "${var.project_name}-replicant-terminate"
  autoscaling_group_name = aws_autoscaling_group.emqx_replicants_asg.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout      = var.lifecycle_hook_timeout_sec
  default_result         = "CONTINUE"
}

resource "aws_iam_role_policy" "emqx_ec2_lifecycle" {
  name = "${var.project_name}-ec2-lifecycle"
  role = aws_iam_role.emqx_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:CompleteLifecycleAction",
          "autoscaling:RecordLifecycleActionHeartbeat",
          "autoscaling:DescribeAutoScalingInstances",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_instance" "load_generator" {
  count = var.enable_load_generator ? 1 : 0

  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.load_generator_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.load_generator_sg[0].id]
  iam_instance_profile        = aws_iam_instance_profile.emqx_ec2.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/userdata/load-generator-setup.sh", {
    project_name = var.project_name
    aws_region   = var.aws_region
  })

  tags = merge(var.tags, {
    Name = "${var.project_name}-load-generator"
    Role = "emqx-load-generator"
  })

  depends_on = [aws_lb_listener.mqtt_1883]
}

resource "aws_security_group" "load_generator_sg" {
  count = var.enable_load_generator ? 1 : 0

  name        = "${var.project_name}-load-generator-sg"
  description = "Load generator for EMQX validation tests (MQTT via NLB)"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "MQTT to NLB, HTTPS for packages/SSM"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-load-generator-sg"
  })
}
