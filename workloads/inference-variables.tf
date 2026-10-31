variable "inference_hostname" {
  description = "Owned DNS hostname for the private HTTPS endpoint, e.g. llm.inference.example.com. Terraform creates a private zone for this exact name."
  type        = string
  validation {
    condition     = length(var.inference_hostname) <= 253 && can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.inference_hostname))
    error_message = "Use a lowercase fully qualified hostname without a trailing dot or wildcard."
  }
}
variable "inference_certificate_validation_zone_id" {
  description = "Existing PUBLIC Route 53 parent zone ID for ACM DNS validation. Its domain must contain inference_hostname; this is separate from the private endpoint zone Terraform creates."
  type        = string
  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.inference_certificate_validation_zone_id))
    error_message = "Provide the public Route 53 hosted zone ID for your owned domain."
  }
}
variable "inference_ingress_cidrs" {
  description = "IPv4 client/VPN CIDRs permitted to connect to the internal inference ALB on HTTPS."
  type        = list(string)
  validation {
    condition     = length(var.inference_ingress_cidrs) > 0 && alltrue([for cidr in var.inference_ingress_cidrs : can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) > 0, false)])
    error_message = "Supply explicit trusted IPv4 CIDRs; 0.0.0.0/0 is not permitted."
  }
}
variable "inference_api_keys" {
  description = "One or more bearer keys for inference; supply TF_VAR_inference_api_keys as a JSON array from your secret store. Multiple keys support overlap during rotation. Stored in Terraform state/Kubernetes Secret."
  type        = list(string)
  sensitive   = true
  validation {
    condition     = length(var.inference_api_keys) > 0 && length(distinct(var.inference_api_keys)) == length(var.inference_api_keys) && alltrue([for key in var.inference_api_keys : can(regex("^[A-Za-z0-9_-]{32,128}$", key))])
    error_message = "Supply distinct randomly generated keys of 32–128 URL-safe alphanumeric, underscore or hyphen characters."
  }
}
variable "inference_gateway_image" {
  description = "Unprivileged NGINX >=1.27.3 image pinned by digest; dynamic ready-pod DNS resolution requires the open-source upstream resolve feature."
  type        = string
  default     = "nginxinc/nginx-unprivileged:1.28-alpine@sha256:7377697a821c131a924a7105fafbe7414db4e9fcc77a6f08f776f33f141ec3f8"
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.inference_gateway_image))
    error_message = "Pin the compatible unprivileged NGINX gateway image by sha256 digest."
  }
}
variable "inference_stream_timeout_seconds" {
  description = "Inactivity timeout for the ALB and gateway; also sets target drain and graceful worker shutdown budgets. Not a guaranteed maximum stream duration."
  type        = number
  default     = 900
  validation {
    condition     = var.inference_stream_timeout_seconds >= 60 && var.inference_stream_timeout_seconds <= 3600 && floor(var.inference_stream_timeout_seconds) == var.inference_stream_timeout_seconds
    error_message = "Use an integer timeout between 60 and 3600 seconds."
  }
}
