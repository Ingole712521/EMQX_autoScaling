locals {
  common_tags = merge(var.tags, {
    NamePrefix = var.project_name
  })

  core_nodes = {
    core1 = { name = "${var.project_name}-core-1", subnet_index = 0, dns = "core1" }
    core2 = { name = "${var.project_name}-core-2", subnet_index = 1, dns = "core2" }
    core3 = { name = "${var.project_name}-core-3", subnet_index = 0, dns = "core3" }
  }

  core_seed_hosts = [
    for c in values(local.core_nodes) : "emqx@${c.dns}.emqx.internal"
  ]
}

module "vpc" {
  source               = "./modules/vpc"
  project_name         = var.project_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = local.common_tags
}

module "security_groups" {
  source                 = "./modules/security-groups"
  project_name           = var.project_name
  vpc_id                 = module.vpc.vpc_id
  dashboard_allowed_cidr = var.dashboard_allowed_cidr
  ssh_allowed_cidr       = var.ssh_allowed_cidr
  tags                   = local.common_tags
}

module "iam" {
  source       = "./modules/iam"
  project_name = var.project_name
  tags         = local.common_tags
}

module "keypair" {
  source                        = "./modules/keypair"
  key_pair_name                 = var.key_pair_name
  create_local_private_key_file = var.create_local_private_key_file
}

module "route53" {
  source       = "./modules/route53"
  project_name = var.project_name
  zone_name    = "emqx.internal"
  vpc_id       = module.vpc.vpc_id
  tags         = local.common_tags
}

module "emqx_core" {
  source                      = "./modules/emqx-core"
  project_name                = var.project_name
  nodes                       = local.core_nodes
  private_subnet_ids          = module.vpc.private_subnet_ids
  security_group_id           = module.security_groups.core_sg_id
  key_name                    = module.keypair.key_name
  instance_profile_name       = module.iam.instance_profile_name
  zone_name                   = module.route53.zone_name
  node_cookie                 = var.emqx_node_cookie
  dashboard_username          = var.emqx_dashboard_username
  dashboard_password          = var.emqx_dashboard_password
  core_seed_hosts             = local.core_seed_hosts
  instance_type               = var.core_instance_type
  core_userdata_template_path = "${path.root}/../userdata/core.sh"
  emqx_tune_nofile              = var.emqx_tune_nofile
  emqx_tune_max_ports           = var.emqx_tune_max_ports
  emqx_tune_acceptors           = var.emqx_tune_acceptors
  emqx_tune_max_connections     = var.emqx_tune_max_connections
  emqx_tune_dist_buffer_size_kb = var.emqx_tune_dist_buffer_size_kb
  tags                        = local.common_tags
}

module "route53_core_records" {
  source       = "./modules/route53"
  project_name = var.project_name
  zone_name    = module.route53.zone_name
  vpc_id       = module.vpc.vpc_id
  zone_id      = module.route53.zone_id
  create_zone  = false
  core_records = {
    for k, v in local.core_nodes : v.dns => module.emqx_core.private_ips[k]
  }
  tags = local.common_tags
}

module "nlb" {
  source            = "./modules/nlb"
  project_name      = var.project_name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  nlb_sg_id         = module.security_groups.nlb_sg_id
  tags              = local.common_tags
}

module "emqx_replicant" {
  source                = "./modules/emqx-replicant"
  project_name          = var.project_name
  private_subnet_ids    = module.vpc.private_subnet_ids
  replicant_sg_id       = module.security_groups.replicant_sg_id
  key_name              = module.keypair.key_name
  instance_profile_name = module.iam.instance_profile_name
  target_group_arns                = [module.nlb.mqtt_target_group_arn]
  node_cookie                      = var.emqx_node_cookie
  dashboard_username               = var.emqx_dashboard_username
  dashboard_password               = var.emqx_dashboard_password
  core_seed_hosts                  = local.core_seed_hosts
  instance_type                    = var.replicant_instance_type
  replicant_userdata_template_path = "${path.root}/../userdata/replicant.sh"
  emqx_tune_nofile              = var.emqx_tune_nofile
  emqx_tune_max_ports           = var.emqx_tune_max_ports
  emqx_tune_acceptors           = var.emqx_tune_acceptors
  emqx_tune_max_connections     = var.emqx_tune_max_connections
  emqx_tune_dist_buffer_size_kb = var.emqx_tune_dist_buffer_size_kb
  health_check_grace_period        = 600
  tags                             = local.common_tags

  depends_on = [module.emqx_core, module.route53_core_records]
}

module "autoscaling" {
  source                          = "./modules/autoscaling"
  project_name                    = var.project_name
  asg_name                        = module.emqx_replicant.asg_name
  nlb_arn_suffix                  = module.nlb.nlb_arn_suffix
  scale_in_cpu_threshold          = 5
  scale_out_network_bytes_per_sec = 5000
  scale_in_metric_period_sec      = 30
  scale_in_evaluation_periods     = 2
  scale_in_cooldown_sec           = 0
  cooldown_sec                    = 60
}

module "cloudwatch" {
  source                   = "./modules/cloudwatch"
  project_name             = var.project_name
  asg_name                 = module.emqx_replicant.asg_name
  nlb_arn_suffix           = module.nlb.nlb_arn_suffix
  mqtt_target_group_suffix = module.nlb.mqtt_target_group_arn_suffix
  cpu_alarm_arn            = module.autoscaling.low_cpu_alarm_arn
  tags                     = local.common_tags
}
