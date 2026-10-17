locals {
  model_names = ["qwen25_7b_instruct", "qwen35_8b", "llama31_8b_instruct"]
  model_json = {
    for name in local.model_names : name => jsonencode({
      model                   = "/models/cache/${name}"
      gpu_memory_utilization  = var.gpu_memory_utilization
      tensor_parallel_size    = 1
      max_model_len           = var.model_max_len
      disable_log_stats       = false
    })
  }
  model_config = {
    for name in local.model_names : name => <<-EOT
      name: "${name}"
      backend: "vllm"
      model_transaction_policy { decoupled: true }
      instance_group [
        {
          count: 1
          kind: KIND_MODEL
        }
      ]
      parameters: {
        key: "REPORT_CUSTOM_METRICS"
        value: { string_value: "true" }
      }
    EOT
  }
}

resource "kubernetes_namespace_v1" "serving" {
  metadata { name = var.namespace }
}

resource "kubernetes_namespace_v1" "observability" {
  metadata { name = "observability" }
}

resource "kubernetes_secret_v1" "artifactory" {
  metadata {
    name      = "artifactory-download-token"
    namespace = kubernetes_namespace_v1.serving.metadata[0].name
  }
  data = { token = var.artifactory_token }
  type = "Opaque"
}

resource "kubernetes_config_map_v1" "artifactory_ca" {
  count = var.artifactory_ca_certificate == "" ? 0 : 1
  metadata {
    name      = "artifactory-ca"
    namespace = kubernetes_namespace_v1.serving.metadata[0].name
  }
  data = { "ca.crt" = var.artifactory_ca_certificate }
}

resource "kubernetes_secret_v1" "ngc_registry" {
  count = var.ngc_api_key == "" ? 0 : 1
  metadata {
    name      = "ngc-registry"
    namespace = kubernetes_namespace_v1.serving.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "nvcr.io" = {
          username = "$oauthtoken"
          password = var.ngc_api_key
          auth     = base64encode("$oauthtoken:${var.ngc_api_key}")
        }
      }
    })
  }
}

resource "kubernetes_storage_class_v1" "efs" {
  metadata { name = "efs-sc" }
  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"
  depends_on          = [data.aws_eks_cluster.cluster]
}

resource "kubernetes_persistent_volume_v1" "models" {
  metadata { name = "model-cache-pv" }
  spec {
    capacity                      = { storage = "1Ti" }
    volume_mode                   = "Filesystem"
    access_modes                  = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name            = kubernetes_storage_class_v1.efs.metadata[0].name
    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        volume_handle = var.efs_file_system_id
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "models" {
  metadata {
    name      = "model-cache"
    namespace = kubernetes_namespace_v1.serving.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.efs.metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.models.metadata[0].name
    resources { requests = { storage = "1Ti" } }
  }
}

resource "kubernetes_config_map_v1" "triton_models" {
  for_each = toset(local.model_names)
  metadata {
    name      = "triton-${each.key}"
    namespace = kubernetes_namespace_v1.serving.metadata[0].name
  }
  data = {
    "config.pbtxt" = local.model_config[each.key]
    "model.json"   = local.model_json[each.key]
  }
}

resource "kubernetes_deployment_v1" "triton" {
  metadata {
    name      = "triton-vllm"
    namespace = kubernetes_namespace_v1.serving.metadata[0].name
    labels    = { app = "triton-vllm" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "triton-vllm" } }
    template {
      metadata { labels = { app = "triton-vllm" } }
      spec {
        termination_grace_period_seconds = 120
        dynamic "image_pull_secrets" {
          for_each = kubernetes_secret_v1.ngc_registry
          content { name = image_pull_secrets.value.metadata[0].name }
        }
        init_container {
          name    = "artifactory-model-cache"
          image   = "curlimages/curl:8.12.1"
          command = ["/bin/sh", "-ec"]
          args = [<<-SCRIPT
            mkdir -p /models/cache /models/repository/qwen25_7b_instruct/1 /models/repository/qwen35_8b/1 /models/repository/llama31_8b_instruct/1
            for model in qwen25_7b_instruct qwen35_8b llama31_8b_instruct; do
              case "$model" in
                qwen25_7b_instruct) url="$URL_QWEN25_7B_INSTRUCT" ;;
                qwen35_8b) url="$URL_QWEN35_8B" ;;
                llama31_8b_instruct) url="$URL_LLAMA31_8B_INSTRUCT" ;;
              esac
              target="/models/cache/$model"
              if [ ! -f "$target/.download-complete" ]; then
                echo "Fetching archive for $model from Artifactory"
                mkdir -p "$target"
                archive="/models/cache/.$model.tar.gz"
                if [ -s /etc/artifactory-ca/ca.crt ]; then
                  curl --fail --location --connect-timeout 30 --max-time 7200 --retry 5 --retry-all-errors --cacert /etc/artifactory-ca/ca.crt --header "Authorization: Bearer $ARTIFACTORY_TOKEN" "$url" -o "$archive"
                else
                  curl --fail --location --connect-timeout 30 --max-time 7200 --retry 5 --retry-all-errors --header "Authorization: Bearer $ARTIFACTORY_TOKEN" "$url" -o "$archive"
                fi
                tar -xzf "$archive" -C "$target"
                rm -f "$archive"
                touch "$target/.download-complete"
              else
                echo "EFS cache hit for $model"
              fi
            done
          SCRIPT
          ]
          env {
            name = "ARTIFACTORY_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.artifactory.metadata[0].name
                key  = "token"
              }
            }
          }
          env {
            name  = "URL_QWEN25_7B_INSTRUCT"
            value = var.model_archive_urls["qwen25_7b_instruct"]
          }
          env {
            name  = "URL_QWEN35_8B"
            value = var.model_archive_urls["qwen35_8b"]
          }
          env {
            name  = "URL_LLAMA31_8B_INSTRUCT"
            value = var.model_archive_urls["llama31_8b_instruct"]
          }
          volume_mount {
            name       = "models"
            mount_path = "/models"
          }
          dynamic "volume_mount" {
            for_each = kubernetes_config_map_v1.artifactory_ca
            content {
              name       = "artifactory-ca"
              mount_path = "/etc/artifactory-ca"
              read_only  = true
            }
          }
        }
        container {
          name              = "triton"
          image             = var.triton_image
          image_pull_policy = "IfNotPresent"
          command           = ["python3"]
          working_dir       = "/opt/tritonserver/python/openai"
          args = [
            "openai_frontend/main.py",
            "--model-repository=/models/repository",
            "--tokenizer=/models/cache/${var.selected_model}",
            "--backend=vllm",
            "--model-control-mode=explicit",
            "--load-model=${var.selected_model}",
            "--openai-port=9000"
          ]
          port {
            name           = "openai"
            container_port = 9000
          }
          port {
            name           = "metrics"
            container_port = 8002
          }
          resources {
            requests = { cpu = "8", memory = "32Gi", "nvidia.com/gpu" = "1" }
            limits   = { cpu = "16", memory = "48Gi", "nvidia.com/gpu" = "1" }
          }
          volume_mount {
            name       = "models"
            mount_path = "/models"
          }
          dynamic "volume_mount" {
            for_each = toset(local.model_names)
            content {
              name       = "config-${volume_mount.value}"
              mount_path = "/models/repository/${volume_mount.value}/config.pbtxt"
              sub_path   = "config.pbtxt"
              read_only  = true
            }
          }
          dynamic "volume_mount" {
            for_each = toset(local.model_names)
            content {
              name       = "config-${volume_mount.value}"
              mount_path = "/models/repository/${volume_mount.value}/1/model.json"
              sub_path   = "model.json"
              read_only  = true
            }
          }
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
          startup_probe {
            http_get {
              path = "/health/ready"
              port = 9000
            }
            failure_threshold = 180
            period_seconds    = 10
          }
          readiness_probe {
            http_get {
              path = "/health/ready"
              port = 9000
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/health/ready"
              port = 9000
            }
            period_seconds = 30
          }
        }
        volume {
          name = "models"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.models.metadata[0].name }
        }
        dynamic "volume" {
          for_each = kubernetes_config_map_v1.artifactory_ca
          content {
            name = "artifactory-ca"
            config_map { name = volume.value.metadata[0].name }
          }
        }
        dynamic "volume" {
          for_each = toset(local.model_names)
          content {
            name = "config-${volume.value}"
            config_map { name = kubernetes_config_map_v1.triton_models[volume.value].metadata[0].name }
          }
        }
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "8Gi"
          }
        }
        node_selector = { workload = "gpu-inference" }
      }
    }
  }
  wait_for_rollout = true
  depends_on = [
    kubernetes_persistent_volume_claim_v1.models,
    helm_release.nvidia_device_plugin
  ]
}

resource "kubernetes_service_v1" "triton" {
  metadata {
    name      = "triton-vllm"
    namespace = kubernetes_namespace_v1.serving.metadata[0].name
    labels    = { app = "triton-vllm" }
  }
  spec {
    selector = { app = "triton-vllm" }
    port {
      name        = "http"
      port        = 8000
      target_port = 9000
    }
    port {
      name        = "metrics"
      port        = 8002
      target_port = 8002
    }
    type = "ClusterIP"
  }
}
