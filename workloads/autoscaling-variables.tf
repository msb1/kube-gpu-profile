variable "karpenter_role_arn" { type = string }
variable "karpenter_node_role_name" { type = string }
variable "karpenter_queue_name" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "node_security_group_id" { type = string }
variable "gpu_instance_types" {
  description = "Allowed single-GPU instance types; unordered, selected by availability and price. Validate model memory and image/driver support on every allowed type."
  type        = list(string)
  default     = ["g7.8xlarge", "g6.8xlarge", "g5.4xlarge"]
  validation {
    condition     = length(var.gpu_instance_types) > 0 && alltrue([for t in var.gpu_instance_types : contains(["g7.8xlarge", "g6.8xlarge", "g5.4xlarge"], t)])
    error_message = "Use the documented single-GPU instance types, removing any incompatible with your model."
  }
}
variable "gpu_ami_id" {
  description = "Explicit tested EKS AL2023 x86_64 NVIDIA AMI ID for the cluster version; pin a driver compatible with the Triton CUDA runtime."
  type        = string
  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.gpu_ami_id))
    error_message = "Pin a tested NVIDIA AMI ID; automatic latest AMI drift is deliberately disabled."
  }
}
variable "min_replicas" {
  type    = number
  default = 1
  validation {
    condition     = var.min_replicas >= 1 && floor(var.min_replicas) == var.min_replicas
    error_message = "At least one replica is required: pod metrics cannot wake a deployment from zero."
  }
}
variable "max_replicas" {
  type    = number
  default = 10
  validation {
    condition     = var.max_replicas >= 1 && floor(var.max_replicas) == var.max_replicas
    error_message = "max_replicas must be a positive integer."
  }
}
variable "kv_cache_target" {
  type    = number
  default = 0.8
  validation {
    condition     = var.kv_cache_target > 0 && var.kv_cache_target < 1
    error_message = "KV cache target is a fraction between zero and one, not percent."
  }
}
variable "waiting_requests_target" {
  type    = number
  default = 4
  validation {
    condition     = var.waiting_requests_target > 0
    error_message = "Waiting requests target must be positive."
  }
}
variable "paused_replicas" {
  description = "Temporarily pause KEDA at this replica count; 0 deliberately suspends serving. Null resumes autoscaling."
  type        = number
  default     = null
  validation {
    condition     = var.paused_replicas == null ? true : var.paused_replicas >= 0 && floor(var.paused_replicas) == var.paused_replicas
    error_message = "paused_replicas must be null or a nonnegative integer."
  }
}
