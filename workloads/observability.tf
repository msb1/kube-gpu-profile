resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.17.1"
  namespace        = "nvidia-device-plugin"
  create_namespace = true
  wait             = true
  timeout          = 900
}

resource "helm_release" "dcgm_exporter" {
  name             = "nvidia-dcgm-exporter"
  repository       = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart            = "dcgm-exporter"
  version          = "4.5.3"
  namespace        = "observability"
  create_namespace = false
  wait             = true
  timeout          = 900
  depends_on       = [kubernetes_namespace_v1.observability]
  values = [yamlencode({
    hostNetwork = var.use_host_dcgm_engine
    arguments   = var.use_host_dcgm_engine ? ["-r", "127.0.0.1:5555"] : []
    customMetrics = <<-CSV
      DCGM_FI_DEV_GPU_UTIL, gauge, GPU utilization percentage.
      DCGM_FI_DEV_FB_USED, gauge, Framebuffer memory used in MiB.
      DCGM_FI_DEV_FB_FREE, gauge, Framebuffer memory free in MiB.
      DCGM_FI_DEV_GPU_TEMP, gauge, GPU temperature in Celsius.
      DCGM_FI_DEV_POWER_USAGE, gauge, GPU power draw in watts.
      DCGM_FI_PROF_PIPE_TENSOR_ACTIVE, gauge, Tensor pipe active ratio.
      DCGM_FI_PROF_SM_ACTIVE, gauge, Ratio of cycles with at least one active warp on an SM.
      DCGM_FI_PROF_DRAM_ACTIVE, gauge, Device memory interface active ratio.
      DCGM_FI_PROF_PIPE_FP16_ACTIVE, gauge, FP16 pipe active ratio.
    CSV
    securityContext = {
      runAsNonRoot = false
      runAsUser    = 0
      capabilities = {
        add  = ["SYS_ADMIN"]
        drop = ["ALL"]
      }
      allowPrivilegeEscalation = false
    }
    serviceMonitor = { enabled = false }
  })]
  set {
    name  = "nodeSelector.workload"
    value = "gpu-inference"
  }
}

resource "helm_release" "pyroscope" {
  name             = "pyroscope"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "pyroscope"
  version          = "1.7.0"
  namespace        = "observability"
  create_namespace = false
  wait             = true
  timeout          = 900
  depends_on       = [kubernetes_namespace_v1.observability]
}

resource "helm_release" "alloy_ebpf_profiler" {
  name             = "alloy-ebpf-profiler"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "alloy"
  version          = "1.13.1"
  namespace        = "observability"
  create_namespace = false
  wait             = true
  timeout          = 900

  values = [yamlencode({
    controller = {
      type      = "daemonset"
      hostPID   = true
      nodeSelector = {
        workload = "gpu-inference"
      }
    }
    alloy = {
      securityContext = {
        privileged = true
        runAsUser  = 0
        runAsGroup = 0
      }
      configMap = {
        content = <<-EOT
          discovery.kubernetes "local_pods" {
            role = "pod"
            selectors {
              field = "spec.nodeName=" + sys.env("HOSTNAME")
              role  = "pod"
            }
          }

          discovery.process "local_processes" {
            join             = discovery.kubernetes.local_pods.targets
            refresh_interval = "15s"
            discover_config {
              exe          = true
              commandline  = true
              container_id = true
            }
          }

          discovery.relabel "triton_processes" {
            targets = discovery.process.local_processes.targets
            rule {
              action        = "keep"
              source_labels = ["__meta_kubernetes_namespace"]
              regex         = "${var.namespace}"
            }
            rule {
              action        = "keep"
              source_labels = ["__meta_kubernetes_pod_label_app"]
              regex         = "triton-vllm"
            }
          }

          pyroscope.ebpf "triton_cpu" {
            targets    = discovery.relabel.triton_processes.output
            forward_to = [pyroscope.write.local.receiver]
          }

          pyroscope.write "local" {
            endpoint {
              url = "http://pyroscope.observability.svc.cluster.local:4040"
            }
          }
        EOT
      }
      mounts = {
        extra = [
          { name = "bpf-fs", mountPath = "/sys/fs/bpf" },
          { name = "symb-cache", mountPath = "/tmp/symb-cache" }
        ]
      }
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
    volumes = {
      extra = [
        { name = "bpf-fs", hostPath = { path = "/sys/fs/bpf", type = "DirectoryOrCreate" } },
        { name = "symb-cache", emptyDir = {} }
      ]
    }
  })]
  depends_on = [helm_release.pyroscope]
}

resource "helm_release" "aws_load_balancer_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "1.14.0"
  namespace        = "kube-system"
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.aws_region
    vpcId       = var.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = var.aws_load_balancer_controller_role_arn
      }
    }
  })]
}

resource "helm_release" "prometheus_stack" {
  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "91.8.2"
  namespace        = "observability"
  create_namespace = false
  wait             = true
  timeout          = 1200

  values = [yamlencode({
    grafana = {
      adminPassword = var.grafana_admin_password
      plugins       = ["grafana-pyroscope-app"]
      additionalDataSources = [{
        name      = "Pyroscope"
        type      = "grafana-pyroscope-datasource"
        access    = "proxy"
        url       = "http://pyroscope.observability.svc.cluster.local:4040"
        isDefault = false
      }]
      dashboards = {
        default = {
          nvidia-dcgm = {
            gnetId     = 12239
            revision   = 3
            datasource = "Prometheus"
          }
          llm-gpu-profiling = {
            json = file("${path.module}/dashboards/llm-gpu-profiling.json")
          }
        }
      }
    }
    prometheus = {
      prometheusSpec = {
        retention = "7d"
        additionalScrapeConfigs = yamldecode(templatefile("${path.module}/prometheus.yml", {
          namespace = var.namespace
        })).scrape_configs
      }
    }
  })]
  depends_on = [kubernetes_service_v1.triton, helm_release.dcgm_exporter, helm_release.pyroscope, helm_release.alloy_ebpf_profiler, helm_release.aws_load_balancer_controller]
}

resource "kubernetes_ingress_v1" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/scheme"           = "internal"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\":80}]"
      "alb.ingress.kubernetes.io/inbound-cidrs"    = join(",", var.grafana_ingress_cidrs)
      "alb.ingress.kubernetes.io/healthcheck-path" = "/api/health"
      "alb.ingress.kubernetes.io/tags"             = "Project=gpu-llm-inference,Application=grafana"
    }
  }
  spec {
    ingress_class_name = "alb"
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "monitoring-grafana"
              port { number = 80 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.prometheus_stack, helm_release.aws_load_balancer_controller]
}

output "grafana_internal_alb_hostname" {
  description = "Internal ALB hostname for Grafana; reachable from the VPC or connected private networks."
  value       = try(kubernetes_ingress_v1.grafana.status[0].load_balancer[0].ingress[0].hostname, null)
}
