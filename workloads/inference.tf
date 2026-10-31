# The parent public zone is a prerequisite. The private endpoint zone, certificate,
# DNS validation records, gateway, Service and dedicated ALB are all Terraform owned.
data "aws_route53_zone" "inference_validation" {
  zone_id = var.inference_certificate_validation_zone_id
}
resource "aws_acm_certificate" "inference" {
  domain_name       = var.inference_hostname
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = !data.aws_route53_zone.inference_validation.private_zone && (var.inference_hostname == trimsuffix(data.aws_route53_zone.inference_validation.name, ".") || endswith(var.inference_hostname, ".${trimsuffix(data.aws_route53_zone.inference_validation.name, ".")}"))
      error_message = "ACM validation requires a PUBLIC parent hosted zone containing inference_hostname."
    }
  }
  tags = { Project = "gpu-llm-inference", Application = "inference" }
}
resource "aws_route53_record" "inference_certificate" {
  zone_id = var.inference_certificate_validation_zone_id
  name    = tolist(aws_acm_certificate.inference.domain_validation_options)[0].resource_record_name
  type    = tolist(aws_acm_certificate.inference.domain_validation_options)[0].resource_record_type
  records = [tolist(aws_acm_certificate.inference.domain_validation_options)[0].resource_record_value]
  ttl     = 60
}
resource "aws_acm_certificate_validation" "inference" {
  certificate_arn         = aws_acm_certificate.inference.arn
  validation_record_fqdns = [aws_route53_record.inference_certificate.fqdn]
}
resource "aws_route53_zone" "inference" {
  name = var.inference_hostname
  vpc { vpc_id = var.vpc_id }
  tags = { Project = "gpu-llm-inference", Application = "inference" }
}

data "kubernetes_service_v1" "cluster_dns" {
  metadata {
    name      = "kube-dns"
    namespace = "kube-system"
  }
}

# DNS returns only ready Triton pod IPs, enabling per-request selection even when
# clients reuse connections and NGINX maintains upstream connection pools.
resource "kubernetes_service_v1" "triton_backends" {
  metadata {
    name      = "triton-backends"
    namespace = var.namespace
  }
  spec {
    cluster_ip                  = "None"
    publish_not_ready_addresses = false
    selector                    = { app = "triton-vllm" }
    port {
      name        = "http"
      port        = 9000
      target_port = 9000
    }
  }
  depends_on = [kubernetes_namespace_v1.serving]
}
locals {
  inference_alb_name = "${substr(var.cluster_name, 0, 15)}-infer-${substr(sha256("${var.cluster_name}/${var.namespace}"), 0, 6)}"
  gateway_config = templatefile("${path.module}/gateway/nginx.conf.tftpl", {
    dns_resolver   = data.kubernetes_service_v1.cluster_dns.spec[0].cluster_ip
    backend_host   = "triton-backends.${var.namespace}.svc.cluster.local"
    stream_timeout = var.inference_stream_timeout_seconds
  })
  gateway_auth = templatefile("${path.module}/gateway/auth.conf.tftpl", { api_keys = var.inference_api_keys })
}
resource "kubernetes_config_map_v1" "inference_gateway" {
  metadata {
    name      = "inference-gateway"
    namespace = var.namespace
  }
  data       = { "nginx.conf" = local.gateway_config }
  depends_on = [kubernetes_namespace_v1.serving]
}
resource "kubernetes_secret_v1" "inference_keys" {
  metadata {
    name      = "inference-api-keys"
    namespace = var.namespace
  }
  data       = { "auth.conf" = local.gateway_auth }
  type       = "Opaque"
  depends_on = [kubernetes_namespace_v1.serving]
}
resource "kubernetes_deployment_v1" "inference_gateway" {
  metadata {
    name      = "inference-gateway"
    namespace = var.namespace
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "inference-gateway" } }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "0"
        max_unavailable = "1"
      }
    }
    template {
      metadata {
        labels = { app = "inference-gateway" }
        annotations = {
          "checksum/config" = sha256(local.gateway_config)
          "checksum/keys"   = sha256(local.gateway_auth)
        }
      }
      spec {
        automount_service_account_token  = false
        node_selector                    = { workload = "system" }
        termination_grace_period_seconds = var.inference_stream_timeout_seconds + 30
        security_context {
          run_as_non_root = true
          run_as_user     = 101
          run_as_group    = 101
          fs_group        = 101
          seccomp_profile { type = "RuntimeDefault" }
        }
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              topology_key = "kubernetes.io/hostname"
              label_selector { match_labels = { app = "inference-gateway" } }
            }
          }
        }
        container {
          name    = "gateway"
          image   = var.inference_gateway_image
          command = ["nginx", "-g", "daemon off;"]
          port {
            name           = "http"
            container_port = 8080
          }
          resources {
            requests = { cpu = "100m", memory = "64Mi" }
            limits   = { cpu = "1", memory = "256Mi" }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
            read_only  = true
          }
          volume_mount {
            name       = "keys"
            mount_path = "/etc/nginx/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 5
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
          lifecycle {
            pre_stop {
              exec { command = ["/bin/sh", "-c", "sleep 15; nginx -s quit"] }
            }
          }
        }
        volume {
          name = "config"
          config_map { name = kubernetes_config_map_v1.inference_gateway.metadata[0].name }
        }
        volume {
          name = "keys"
          secret { secret_name = kubernetes_secret_v1.inference_keys.metadata[0].name }
        }
        volume {
          name = "tmp"
          empty_dir { size_limit = "64Mi" }
        }
      }
    }
  }
  depends_on = [kubernetes_service_v1.triton_backends]
  timeouts { update = "130m" }
}
resource "kubernetes_pod_disruption_budget_v1" "inference_gateway" {
  metadata {
    name      = "inference-gateway"
    namespace = var.namespace
  }
  spec {
    min_available = "1"
    selector { match_labels = { app = "inference-gateway" } }
  }
  depends_on = [kubernetes_namespace_v1.serving]
}
resource "kubernetes_service_v1" "inference_gateway" {
  metadata {
    name      = "inference-gateway"
    namespace = var.namespace
  }
  spec {
    selector = { app = "inference-gateway" }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
    type = "ClusterIP"
  }
  depends_on = [kubernetes_namespace_v1.serving]
}
resource "kubernetes_network_policy_v1" "triton" {
  metadata {
    name      = "triton-gateway-only"
    namespace = var.namespace
  }
  spec {
    pod_selector { match_labels = { app = "triton-vllm" } }
    policy_types = ["Ingress"]
    ingress {
      from {
        pod_selector { match_labels = { app = "inference-gateway" } }
      }
      ports {
        protocol = "TCP"
        port     = "9000"
      }
    }
    ingress {
      from {
        namespace_selector { match_labels = { "kubernetes.io/metadata.name" = "observability" } }
        pod_selector { match_labels = { "app.kubernetes.io/name" = "prometheus" } }
      }
      ports {
        protocol = "TCP"
        port     = "8002"
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.serving]
}
resource "kubernetes_ingress_v1" "inference" {
  wait_for_load_balancer = true
  metadata {
    name      = "inference"
    namespace = var.namespace
    annotations = {
      "alb.ingress.kubernetes.io/load-balancer-name"       = local.inference_alb_name
      "alb.ingress.kubernetes.io/scheme"                   = "internal"
      "alb.ingress.kubernetes.io/subnets"                  = join(",", var.private_subnet_ids)
      "alb.ingress.kubernetes.io/target-type"              = "ip"
      "alb.ingress.kubernetes.io/listen-ports"             = "[{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/certificate-arn"          = aws_acm_certificate_validation.inference.certificate_arn
      "alb.ingress.kubernetes.io/ssl-policy"               = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      "alb.ingress.kubernetes.io/inbound-cidrs"            = join(",", var.inference_ingress_cidrs)
      "alb.ingress.kubernetes.io/healthcheck-path"         = "/healthz"
      "alb.ingress.kubernetes.io/healthcheck-port"         = "traffic-port"
      "alb.ingress.kubernetes.io/success-codes"            = "200"
      "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=${var.inference_stream_timeout_seconds},routing.http.drop_invalid_header_fields.enabled=true"
      "alb.ingress.kubernetes.io/target-group-attributes"  = "deregistration_delay.timeout_seconds=${var.inference_stream_timeout_seconds},stickiness.enabled=false"
      "alb.ingress.kubernetes.io/tags"                     = "Project=gpu-llm-inference,Application=inference"
    }
  }
  spec {
    ingress_class_name = "alb"
    rule {
      host = var.inference_hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.inference_gateway.metadata[0].name
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.aws_load_balancer_controller, kubernetes_deployment_v1.inference_gateway, kubernetes_network_policy_v1.triton]
  timeouts { create = "20m" }
}
data "aws_lb" "inference" {
  name       = local.inference_alb_name
  depends_on = [kubernetes_ingress_v1.inference]
}
resource "aws_route53_record" "inference" {
  zone_id = aws_route53_zone.inference.zone_id
  name    = var.inference_hostname
  type    = "A"
  alias {
    name                   = data.aws_lb.inference.dns_name
    zone_id                = data.aws_lb.inference.zone_id
    evaluate_target_health = true
  }
}
output "inference_base_url" {
  description = "Private HTTPS OpenAI API base URL; supply a configured bearer API key."
  value       = "https://${trimsuffix(aws_route53_record.inference.fqdn, ".")}/v1"
}
output "inference_internal_alb_hostname" { value = data.aws_lb.inference.dns_name }
output "inference_private_zone_id" { value = aws_route53_zone.inference.zone_id }
output "inference_certificate_arn" { value = aws_acm_certificate_validation.inference.certificate_arn }
