variable "aws_region" {
  description = "AWS region for the cluster and GPU capacity."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Short prefix used for AWS resource names."
  type        = string
  default     = "llm-profile"
}

variable "vpc_cidr" {
  description = "CIDR range for the dedicated VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version supported in the selected region."
  type        = string
  default     = "1.33"
}

variable "gpu_instance_type" {
  description = "GPU EC2 type. Preferred default is g7.8xlarge; select g5.4xlarge or g6.8xlarge if needed."
  type        = string
  default     = "g7.8xlarge"
}

variable "gpu_min_size" {
  type        = number
  description = "Minimum GPU worker count. Set to 0 to scale down when idle."
  default     = 1
}

variable "gpu_desired_size" {
  type        = number
  description = "Initial GPU worker count. A single-GPU node can serve one selected 7B/8B model at a time."
  default     = 1
}

variable "gpu_max_size" {
  type        = number
  description = "Maximum GPU worker count."
  default     = 1
}

variable "install_dcgm_cli" {
  description = "When true, use Systems Manager to install the CUDA-compatible NVIDIA DCGM package and host engine on EKS GPU nodes."
  type        = bool
  default     = false
}

variable "admin_cidr_blocks" {
  description = "CIDR ranges allowed to reach the EKS public API endpoint. Use trusted office/VPN IPs."
  type        = list(string)
}

variable "cluster_admin_arn" {
  description = "IAM user or role ARN for the Terraform operator; do not use an STS assumed-role session ARN."
  type        = string
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to AWS resources."
  default     = { Project = "gpu-llm-inference" }
}
