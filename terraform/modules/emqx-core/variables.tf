variable "project_name" { type = string }
variable "nodes" { type = map(any) }
variable "private_subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }
variable "key_name" { type = string }
variable "instance_profile_name" { type = string }
variable "zone_name" { type = string }
variable "node_cookie" { type = string }
variable "dashboard_username" { type = string }
variable "dashboard_password" { type = string }
variable "core_seed_hosts" { type = list(string) }
variable "instance_type" { type = string }
variable "core_userdata_template_path" { type = string }
variable "tags" { type = map(string) }

variable "emqx_tune_nofile" {
  type    = number
  default = 2097152
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
