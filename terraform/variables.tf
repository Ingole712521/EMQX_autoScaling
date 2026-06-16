variable "aws_region" {
  description = "AWS region for deployment."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project prefix for all resources."
  type        = string
  default     = "emqx-demo"
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs used by the project."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "core_instance_type" {
  description = "EC2 instance type for core nodes."
  type        = string
  default     = "t3.medium"
}

variable "replicant_instance_type" {
  description = "EC2 instance type for replicant nodes."
  type        = string
  default     = "t3.medium"
}

variable "dashboard_allowed_cidr" {
  description = "CIDR allowed to access EMQX dashboard."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to access SSH."
  type        = string
  default     = "0.0.0.0/0"
}

variable "emqx_node_cookie" {
  description = "Shared EMQX node cookie."
  type        = string
  sensitive   = true
}

variable "emqx_dashboard_username" {
  description = "EMQX dashboard default username."
  type        = string
  default     = "admin"
}

variable "emqx_dashboard_password" {
  description = "EMQX dashboard default password."
  type        = string
  sensitive   = true
}

variable "emqx_tune_nofile" {
  description = "Open file descriptor limit (EMQX performance tuning)."
  type        = number
  default     = 2097152
}

variable "emqx_tune_max_ports" {
  type    = number
  default = 2097152
}

variable "emqx_tune_acceptors" {
  type    = number
  default = 64
}

variable "emqx_tune_max_connections" {
  type    = number
  default = 1024000
}

variable "emqx_tune_dist_buffer_size_kb" {
  type    = number
  default = 2097151
}

variable "key_pair_name" {
  description = "Single key pair name for all EMQX instances."
  type        = string
  default     = "emqx-demo-key"
}

variable "create_local_private_key_file" {
  description = "Whether to write generated private key to disk."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default = {
    Environment = "interview-demo"
    ManagedBy   = "terraform"
    Project     = "emqx"
  }
}
