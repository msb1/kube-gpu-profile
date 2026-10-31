resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.8.1"
  timeout          = 900
  atomic           = true
  values = [yamlencode({
    replicas       = 2
    nodeSelector   = { workload = "system" }
    serviceAccount = { annotations = { "eks.amazonaws.com/role-arn" = var.karpenter_role_arn } }
    settings = {
      clusterName       = var.cluster_name
      clusterEndpoint   = data.aws_eks_cluster.cluster.endpoint
      interruptionQueue = var.karpenter_queue_name
    }
    controller = { resources = { requests = { cpu = "500m", memory = "512Mi" }, limits = { memory = "1Gi" } } }
  })]
}
resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.18.1"
  timeout          = 900
  atomic           = true
  values = [yamlencode({
    nodeSelector  = { workload = "system" }
    operator      = { replicaCount = 2, affinity = local.keda_affinity["keda-operator"] }
    metricsServer = { replicaCount = 2, affinity = local.keda_affinity["keda-operator-metrics-apiserver"] }
    webhooks      = { replicaCount = 2, affinity = local.keda_affinity["keda-admission-webhooks"] }
  })]
}

# Helm renders these after controller installation, avoiding kubernetes_manifest's
# plan-time CRD discovery failure on a new cluster (depends_on alone cannot fix it).
resource "helm_release" "gpu_capacity" {
  name      = "gpu-capacity"
  namespace = "karpenter"
  chart     = "${path.module}/charts/resources"
  timeout   = 900
  values = [yamlencode({ resources = [
    {
      apiVersion = "karpenter.k8s.aws/v1"
      kind       = "EC2NodeClass"
      metadata   = { name = "gpu-inference" }
      spec = {
        role                       = var.karpenter_node_role_name
        amiFamily                  = "AL2023"
        amiSelectorTerms           = [{ id = var.gpu_ami_id }]
        subnetSelectorTerms        = [for id in var.private_subnet_ids : { id = id }]
        securityGroupSelectorTerms = [{ id = var.node_security_group_id }]
        metadataOptions            = { httpEndpoint = "enabled", httpTokens = "required", httpPutResponseHopLimit = 1 }
        blockDeviceMappings = [{ deviceName = "/dev/xvda", ebs = {
          volumeSize = "200Gi", volumeType = "gp3", iops = 6000, throughput = 250, encrypted = true, deleteOnTermination = true
        } }]
        tags = { "gpu-profile-cluster" = var.cluster_name, "Workload" = "llm-triton-inference" }
      }
    },
    {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata   = { name = "gpu-inference" }
      spec = {
        limits     = { "nvidia.com/gpu" = tostring(var.max_replicas + 1), cpu = tostring(32 * (var.max_replicas + 1)), memory = "${128 * (var.max_replicas + 1)}Gi" }
        disruption = { consolidationPolicy = "WhenEmpty", consolidateAfter = "10m", budgets = [{ nodes = "1" }] }
        template = {
          metadata = { labels = { workload = "gpu-inference" } }
          spec = {
            nodeClassRef           = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "gpu-inference" }
            expireAfter            = "Never"
            terminationGracePeriod = "15m"
            taints                 = [{ key = "nvidia.com/gpu", value = "present", effect = "NoSchedule" }]
            requirements = [
              { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
              { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
              { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
              { key = "node.kubernetes.io/instance-type", operator = "In", values = var.gpu_instance_types }
            ]
          }
        }
      }
    }
  ] })]
  depends_on = [helm_release.karpenter]
}

locals {
  keda_affinity = { for app in ["keda-operator", "keda-operator-metrics-apiserver", "keda-admission-webhooks"] : app => {
    podAntiAffinity = { requiredDuringSchedulingIgnoredDuringExecution = [{
      labelSelector = { matchLabels = { app = app } }
      topologyKey   = "kubernetes.io/hostname"
    }] }
  } }
  # Only current, successfully scraped pods; stale gauges must not drive scaling.
  autoscale_selector = "job=\"triton-vllm\",namespace=\"${var.namespace}\",model=\"${var.selected_model}\""
  healthy_stats      = "(time() - llm_scheduler_update_timestamp_seconds{${local.autoscale_selector}} < 45) and on(instance) (up{job=\"triton-vllm\",namespace=\"${var.namespace}\"} == 1) and on(namespace,pod) (kube_pod_status_ready{namespace=\"${var.namespace}\",condition=\"true\"} == 1)"
  # Refuse an apparently low demand result when any ready pod is missing stats.
  complete_stats = "count(${local.healthy_stats}) == on() max(kube_deployment_status_replicas_ready{namespace=\"${var.namespace}\",deployment=\"triton-vllm\"})"
  kv_query       = "avg(llm_kv_cache_usage_ratio{${local.autoscale_selector}} and on(instance,model) (${local.healthy_stats})) and on() (${local.complete_stats})"
  queue_query    = "sum(avg_over_time(llm_num_requests_waiting{${local.autoscale_selector}}[15s]) and on(instance,model) (${local.healthy_stats})) and on() (${local.complete_stats})"
}
resource "helm_release" "triton_scaling" {
  name      = "triton-scaling"
  namespace = var.namespace
  chart     = "${path.module}/charts/resources"
  values = [yamlencode({ resources = [{
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name        = "triton-vllm", namespace = var.namespace
      annotations = var.paused_replicas == null ? {} : { "autoscaling.keda.sh/paused-replicas" = tostring(var.paused_replicas) }
    }
    spec = {
      scaleTargetRef  = { name = kubernetes_deployment_v1.triton.metadata[0].name }
      pollingInterval = 15
      minReplicaCount = var.min_replicas
      maxReplicaCount = var.max_replicas
      cooldownPeriod  = 900
      advanced = { horizontalPodAutoscalerConfig = { behavior = {
        scaleUp   = { stabilizationWindowSeconds = 0, policies = [{ type = "Percent", value = 100, periodSeconds = 15 }] }
        scaleDown = { stabilizationWindowSeconds = 900, policies = [{ type = "Pods", value = 1, periodSeconds = 60 }] }
      } } }
      triggers = [
        { type = "prometheus", metricType = "Value", metadata = {
          serverAddress = "http://monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090"
          query         = local.kv_query, threshold = tostring(var.kv_cache_target), ignoreNullValues = "false"
        } },
        { type = "prometheus", metricType = "AverageValue", metadata = {
          serverAddress = "http://monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090"
          query         = local.queue_query, threshold = tostring(var.waiting_requests_target), ignoreNullValues = "false"
        } }
      ]
    }
  }] })]
  lifecycle {
    precondition {
      condition     = var.max_replicas >= var.min_replicas && (var.paused_replicas == null ? true : var.paused_replicas <= var.max_replicas)
      error_message = "max_replicas must be at least min_replicas, and paused_replicas must not exceed max_replicas."
    }
  }
  depends_on = [helm_release.keda, helm_release.prometheus_stack]
}
