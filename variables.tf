variable "aws_region" {
  description = "AWS region for EMQX deployment."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project/name prefix for all resources."
  type        = string
  default     = "emqx-prod"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs for 2 public subnets in different AZs."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "availability_zones" {
  description = "Two availability zones for high availability."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "core_instance_type" {
  description = "EC2 instance type for permanent EMQX core."
  type        = string
  default     = "t3.small"
}

variable "replicant_instance_type" {
  description = "EC2 instance type for auto-scaled EMQX replicants."
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Optional EC2 key pair name for SSH access."
  type        = string
  default     = null
}

variable "dashboard_allowed_cidr" {
  description = "CIDR allowed to access EMQX dashboard on port 18083."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to access SSH on port 22."
  type        = string
  default     = "0.0.0.0/0"
}

variable "emqx_node_cookie" {
  description = "Shared Erlang cookie for EMQX cluster nodes."
  type        = string
  sensitive   = true
}

variable "emqx_dashboard_username" {
  description = "Dashboard admin username."
  type        = string
  default     = "admin"
}

variable "emqx_dashboard_password" {
  description = "Dashboard admin password."
  type        = string
  sensitive   = true
}

variable "emqx_version" {
  description = "EMQX DEB package version to install (5.8.x)."
  type        = string
  default     = "5.8.9"
}

variable "replicant_min_size" {
  description = "Minimum replicant nodes in ASG."
  type        = number
  default     = 1
}

variable "replicant_desired_capacity" {
  description = "Desired replicant nodes in ASG."
  type        = number
  default     = 1
}

variable "replicant_max_size" {
  description = "Maximum replicant nodes in ASG."
  type        = number
  default     = 4
}

variable "scale_out_network_target_bytes" {
  description = "Scale out (+1) when NLB/ASG network exceeds this value (bytes/sec). 5000 ~= 300 KB per 60s CloudWatch period."
  type        = number
  default     = 5000
}

variable "scale_out_cpu_threshold" {
  description = "Backup scale-out when ASG average CPU exceeds this percent (MQTT load on t3.small)."
  type        = number
  default     = 25
}

variable "scale_out_network_evaluation_periods" {
  description = "Consecutive 60s periods network must exceed threshold before scale-out. Use 2+ to ignore brief bootstrap spikes."
  type        = number
  default     = 2
}

variable "autoscaling_cooldown_sec" {
  description = "Cooldown after scale-out actions (seconds)."
  type        = number
  default     = 60
}

variable "scale_in_cooldown_sec" {
  description = "Cooldown after scale-in actions. Use 0 for fastest instance removal."
  type        = number
  default     = 0
}

variable "scale_in_metric_period_sec" {
  description = "CloudWatch period for scale-in CPU alarm. Use 30 with detailed EC2 monitoring for sub-minute scale-in."
  type        = number
  default     = 30
}

variable "scale_in_evaluation_periods" {
  description = "Consecutive low-CPU periods required before scale-in. With period=30 and value=2, scale-in triggers in ~60s."
  type        = number
  default     = 2
}

variable "scale_in_cpu_threshold" {
  description = "Scale in (-1) when ASG average CPU stays below this percent for scale_in_evaluation_periods."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
    Workload    = "emqx"
  }
}

variable "lifecycle_hook_timeout_sec" {
  description = "ASG lifecycle hook heartbeat timeout while replicant drains MQTT sessions on scale-in/termination."
  type        = number
  default     = 120
}

variable "lifecycle_drain_grace_sec" {
  description = "Seconds to wait after stopping EMQX before completing the lifecycle hook."
  type        = number
  default     = 30
}

variable "enable_load_generator" {
  description = "Provision a dedicated EC2 instance for resilience and durability validation tests."
  type        = bool
  default     = true
}

variable "load_generator_instance_type" {
  description = "Instance type for the validation load-generator EC2."
  type        = string
  default     = "t3.small"
}

variable "mqtt_max_mqueue_len" {
  description = "EMQX per-session message queue length (mqtt.max_mqueue_len)."
  type        = number
  default     = 100000
}

variable "mqtt_session_expiry_interval" {
  description = "EMQX session expiry interval for durable sessions (e.g. 2h)."
  type        = string
  default     = "2h"
}

variable "mqtt_retry_interval" {
  description = "EMQX MQTT retry interval for QoS 1/2 (e.g. 30s)."
  type        = string
  default     = "30s"
}
