# Opportunistic cache warming only. A fresh EC2 node still downloads this image;
# use a tested image-baked AMI to eliminate that first download.
resource "kubernetes_daemon_set_v1" "triton_image_cache" {
  metadata {
    name      = "triton-image-cache"
    namespace = var.namespace
  }
  spec {
    selector { match_labels = { app = "triton-image-cache" } }
    template {
      metadata { labels = { app = "triton-image-cache" } }
      spec {
        node_selector = { workload = "gpu-inference" }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "present"
          effect   = "NoSchedule"
        }
        dynamic "image_pull_secrets" {
          for_each = kubernetes_secret_v1.ngc_registry
          content { name = image_pull_secrets.value.metadata[0].name }
        }
        container {
          name              = "cache"
          image             = var.triton_image
          image_pull_policy = "IfNotPresent"
          command           = ["python3", "-c", "import time; time.sleep(2147483647)"]
          env {
            name  = "NVIDIA_VISIBLE_DEVICES"
            value = "void"
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }
        }
      }
    }
  }
  # A DaemonSet must not block apply while the GPU pool is empty.
  wait_for_rollout = false
}
resource "kubernetes_pod_disruption_budget_v1" "triton" {
  metadata {
    name      = "triton-vllm"
    namespace = var.namespace
  }
  spec {
    min_available = "1"
    selector { match_labels = { app = "triton-vllm" } }
  }
}
