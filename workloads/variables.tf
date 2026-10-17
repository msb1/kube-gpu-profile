variable "aws_region" {
  description = "Region containing the EKS cluster."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name output by the infra Terraform root."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID output by the infra root; used to configure AWS Load Balancer Controller."
  type        = string
}

variable "efs_file_system_id" {
  description = "Encrypted EFS filesystem ID output by the infra Terraform root."
  type        = string
}

variable "aws_load_balancer_controller_role_arn" {
  description = "IRSA role ARN output by the infra root for AWS Load Balancer Controller."
  type        = string
}

variable "grafana_ingress_cidrs" {
  description = "Client source CIDRs (typically VPN/NAT egress ranges) allowed to reach the internal Grafana ALB. Set to the actual source range seen by the VPC."
  type        = list(string)
  validation {
    condition     = length(var.grafana_ingress_cidrs) > 0 && alltrue([for cidr in var.grafana_ingress_cidrs : can(cidrhost(cidr, 0))])
    error_message = "grafana_ingress_cidrs must contain at least one valid trusted network CIDR."
  }
}

variable "model_archive_urls" {
  description = "Direct HTTPS download URL for a tar.gz archive for each model; archives must contain model weights/tokenizer files at their root."
  type        = map(string)
  sensitive   = false
  validation {
    condition = alltrue([
      for key in ["qwen25_7b_instruct", "qwen35_8b", "llama31_8b_instruct"] :
      contains(keys(var.model_archive_urls), key) && startswith(lookup(var.model_archive_urls, key, ""), "https://")
    ])
    error_message = "Provide HTTPS archive URLs for qwen25_7b_instruct, qwen35_8b, and llama31_8b_instruct."
  }
}

variable "selected_model" {
  description = "Model Triton should load on the one-GPU node at deployment time. Other model archives remain cached on EFS."
  type        = string
  default     = "qwen25_7b_instruct"
  validation {
    condition     = contains(["qwen25_7b_instruct", "qwen35_8b", "llama31_8b_instruct"], var.selected_model)
    error_message = "selected_model must be qwen25_7b_instruct, qwen35_8b, or llama31_8b_instruct."
  }
}

variable "use_host_dcgm_engine" {
  description = "Connect DCGM Exporter to the host DCGM engine installed by infra.install_dcgm_cli. Enable this in both Terraform roots together."
  type        = bool
  default     = false
}

variable "artifactory_token" {
  description = "JFrog access token used as an Authorization: Bearer credential by the model download init container. Pass via TF_VAR_artifactory_token or a secret manager; never commit it."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.artifactory_token) > 0
    error_message = "artifactory_token must not be empty."
  }
}

variable "artifactory_ca_certificate" {
  description = "Optional PEM CA certificate used to validate a private JFrog HTTPS endpoint. Leave empty for public CA certificates."
  type        = string
  default     = ""
}

variable "grafana_admin_password" {
  description = "Grafana initial admin password. Supply through TF_VAR_grafana_admin_password; rotate after first login."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.grafana_admin_password) >= 16
    error_message = "Use a Grafana admin password of at least 16 characters."
  }
}

variable "ngc_api_key" {
  description = "Optional NVIDIA NGC API key for nvcr.io pulls. Supply through TF_VAR_ngc_api_key; Terraform/Kubernetes state contains it when set."
  type        = string
  sensitive   = true
  default     = ""
}

variable "triton_image" {
  description = "NVIDIA Triton image tag that includes the vLLM backend; confirm the backend/model compatibility before changing."
  type        = string
  default     = "nvcr.io/nvidia/tritonserver:26.04-vllm-python-py3"
}

variable "namespace" {
  type        = string
  description = "Namespace for the model-serving workload."
  default     = "llm-serving"
}

variable "model_max_len" {
  type        = number
  description = "Maximum context length passed to the vLLM backend; reduce this if GPU memory is constrained."
  default     = 8192
}

variable "gpu_memory_utilization" {
  type        = number
  description = "vLLM fraction of GPU memory available for weights and KV cache."
  default     = 0.88
}
