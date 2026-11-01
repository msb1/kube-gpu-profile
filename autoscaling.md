# KEDA, Karpenter, and the custom Triton metrics image

The inference access path is fully defined in Terraform: private HTTPS ALB → API-key gateway → ready Triton pods, with managed ACM/private DNS and backend policy. See [inference.md](inference.md) for setup and streaming behavior.

This reference implementation preserves Triton’s OpenAI frontend, all three model archives, selected-model switching, EFS caching, Grafana’s private ALB, DCGM, Pyroscope, Alloy, optional host DCGM, and the existing managed GPU group. KEDA adds/removes serving replicas; Karpenter provisions and removes GPU EC2 nodes. The managed GPU group remains available for migration/manual capacity, with zero desired capacity by default. Two CPU system nodes keep the controllers, DNS, EFS controller and monitoring alive independently of GPU demand.

The serving floor is one replica. This is intentional: metrics produced by a stopped inference server cannot detect new HTTP demand. Scale-to-zero with automatic wake-up needs a separately designed request gateway/buffer or durable queue. No such gateway is silently substituted for the existing synchronous OpenAI service.

## What scales and why

Each Triton serving pod runs one selected model through vLLM and requests one GPU. The vLLM scheduler tracks work inside that engine. A custom extension in the Triton image exports scheduler statistics as Prometheus metrics; Prometheus scrapes each pod; and two KEDA Prometheus triggers make those measurements available to a Kubernetes Horizontal Pod Autoscaler (HPA). The HPA changes the Triton Deployment's desired replica count. If a new pod cannot be scheduled because no suitable GPU is available, Karpenter provisions an eligible GPU node. The pod then starts and initializes its own model copy before becoming ready to receive traffic.

```text
vLLM scheduler on each serving pod
  -> custom Triton metrics extension -> Prometheus
  -> KEDA Prometheus triggers -> Kubernetes HPA
  -> Triton replica count -> pending GPU pod, if capacity is unavailable
  -> Karpenter GPU node -> model initialization -> ready serving pod
```

KEDA creates and configures the HPA through a `ScaledObject`; it does not itself move a running model or add GPU capacity. Karpenter responds to unschedulable pods, not directly to the scheduler metrics. Consequently, a scale-up decision does not immediately provide serving capacity: node provisioning, image availability, pod startup and model loading all contribute to the delay. Existing streams stay on their original replica.

| Layer | Mechanism | Default |
|---|---|---|
| Pods | KEDA Prometheus triggers create one native HPA | 1–10 replicas |
| KV pressure | Mean current `llm_kv_cache_usage_ratio`, HPA `Value` target | 0.8 (80%) |
| Waiting work | Sum of each pod’s 15-second mean `llm_num_requests_waiting`, HPA `AverageValue` target | 4 requests per replica |
| Scale up | HPA chooses the larger desired count from either metric | Up to 100% per 15 seconds |
| Scale down | HPA stabilization plus rate limit | 900 seconds, at most one pod per minute |
| GPU capacity | Karpenter single-GPU On-Demand NodePool | At most max replicas + one rollout node, subject to eventual consistency |
| Empty nodes | Karpenter consolidation | Empty for 10 minutes |
| CPU system capacity | Managed EKS node group | Two nodes, independent of demand |

### Trigger 1: KV-cache pressure

The KV cache holds intermediate attention data used when processing and generating tokens. Each vLLM scheduler reports its current KV-cache usage as `llm_kv_cache_usage_ratio`, a fraction from 0 to 1. Prometheus calculates the mean across eligible serving pods. The default target, `kv_cache_target = 0.8`, is 80% usage. This measures scheduler KV-cache pressure, not total GPU framebuffer utilization.

The trigger uses HPA metric type `Value`. Its approximate recommendation is:

```text
desired replicas = ceil(current replicas × mean KV usage / KV target)
```

For example, four replicas averaging 0.9 usage at the default 0.8 target produce `ceil(4 × 0.9 / 0.8) = 5`. KV usage is a pressure signal, not a request count. An idle engine can retain prefix cache, so usage may remain elevated after traffic falls; see the tuning guidance below.

### Trigger 2: waiting requests

Each scheduler reports `llm_num_requests_waiting`, the number of requests waiting inside vLLM. The Prometheus query takes a 15-second average for each eligible pod, then sums those averages across the fleet. This smooths short fluctuations while measuring total waiting work. The default `waiting_requests_target = 4` is a target of four waiting requests per replica.

The trigger uses HPA metric type `AverageValue`. Its approximate recommendation is:

```text
desired replicas = ceil(total of per-pod 15-second waiting averages / waiting target)
```

For example, a fleet total of 20 averaged waiting requests at the default target produces `ceil(20 / 4) = 5` replicas. This is the vLLM internal queue; it is not necessarily the same as Triton's pending-request gauge.

### Combining triggers and controlling the rate

The HPA calculates a recommendation for each metric and uses the larger one. Either high KV pressure or waiting work can request scale-up; both metrics must permit a reduction before scale-down. The formulas above are approximations: Kubernetes also applies tolerance, readiness and missing-metric handling, stabilization, rate policies and the configured replica bounds. A threshold crossing does not guarantee immediate scaling.

The default range is one to ten replicas. Scale-up has no stabilization window and can increase the count by up to 100% per 15 seconds. Scale-down uses a 900-second stabilization window and removes at most one pod per minute. This gives demand time to settle before removing capacity that would be costly to reload. The separate KEDA `cooldownPeriod` of 900 seconds concerns transitions to zero; it does not replace the HPA scale-down window. Normal automatic operation retains at least one replica because a stopped engine cannot report new HTTP demand, and the gateway does not wake it. The deliberate `paused_replicas = 0` setting suspends serving until autoscaling is resumed.

### Metric freshness and completeness

Prometheus discovers each Triton pod IP, rather than scraping the load-balanced Service address. Its scrape interval is 5 seconds, so the queue’s 15-second range contains multiple samples. Queries select the configured namespace and selected model, and use ready pods with successful scrapes and scheduler timestamps younger than 45 seconds. Empty results are errors (`ignoreNullValues=false`), never coerced to zero. An unavailable metric must not be interpreted as idle. Existing valid zero values remain valid. A completeness check compares fresh, successfully scraped ready-pod statistics with kube-state-metrics’ ready replica count; partial scrape loss returns an error rather than a misleading fleet average. This also depends on kube-state-metrics being available. A `TritonAutoscalingTelemetryIncomplete` alert fires after two minutes without complete telemetry; configure Alertmanager destinations for notification.

The HPA owns `Deployment.spec.replicas`; Terraform ignores subsequent replica changes. Change bounds through `min_replicas` and `max_replicas`, not `kubectl scale` during normal operation. The original GPU min/desired/max variables control only the legacy managed GPU group.

## Custom image and metrics contract

The Docker context is [images/triton-metrics](images/triton-metrics). It extends `nvcr.io/nvidia/tritonserver:26.04-vllm-python-py3` without installing a different vLLM version. `install.py` checks the SHA-256 of the reviewed upstream `utils/metrics.py` before appending an import of our extension. Any upstream difference stops the build and requires review. The fingerprint was obtained from NVIDIA’s `r26.04` source; the actual base image must match it. A mismatch is a review gate, not a reason to remove the check.

The extension replaces the logger class resolved by NVIDIA’s existing factory with a subclass. The subclass retains upstream token counters, latency histograms and finalization, and adds three Triton MetricFamily gauges on port 8002:

| Metric | Source | Unit |
|---|---|---|
| `llm_kv_cache_usage_ratio` | `SchedulerStats.kv_cache_usage` | Fraction 0–1, not percent |
| `llm_num_requests_waiting` | `SchedulerStats.num_waiting_reqs` | Requests |
| `llm_scheduler_update_timestamp_seconds` | Last valid callback | Unix seconds |

The class checks the scheduler fields at startup, supports one engine per replica, and updates gauges even when there are no iteration statistics. Invalid values do not refresh the timestamp. Triton `REPORT_CUSTOM_METRICS=true` and vLLM `disable_log_stats=false` remain configured. GPU framebuffer utilization is not KV-cache utilization; no DCGM approximation is used. Triton’s pending-request gauge does not necessarily measure vLLM’s internal waiting queue because decoupled requests may already have entered the backend.

For a release, resolve the NVIDIA base image to its immutable digest and build on an amd64 Docker builder. Example after creating an ECR repository and authenticating Docker to NGC (if required) and ECR:

```sh
export BASE_IMAGE='nvcr.io/nvidia/tritonserver:26.04-vllm-python-py3@sha256:REPLACE_WITH_BASE_DIGEST'
export IMAGE='123456789012.dkr.ecr.us-east-1.amazonaws.com/triton-autoscaling:26.04-metrics-v1'
docker buildx build --platform linux/amd64 \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --tag "$IMAGE" --push images/triton-metrics
aws ecr describe-images --repository-name triton-autoscaling \
  --image-ids imageTag=26.04-metrics-v1 --query 'imageDetails[0].imageDigest' --output text
```

Set `triton_image` to `repository@sha256:…` using that returned digest. It is a required input: the stock image cannot satisfy the autoscaling contract. ECR images use the node role’s pull permissions; `ngc_api_key` still supports direct NGC pulls. For other private registries, supply an appropriate image pull secret rather than reusing NGC credentials.

## Infrastructure and Kubernetes lifecycle

Apply `infra/` first. Its pinned upstream Karpenter IAM module supplies the controller’s scoped v1 permissions, IRSA trust, node role/EKS access entry, encrypted SQS interruption queue, and EventBridge events. Controllers run on the `workload=system` CPU group; Karpenter and each KEDA component have two replicas with anti-affinity across hosts; they do not require a GPU to start. The node role includes SSM permissions for the optional DCGM diagnostic feature.

Copy `karpenter_role_arn`, `karpenter_node_role_name`, `karpenter_queue_name`, `private_subnet_ids`, and `node_security_group_id` from infra outputs to workloads inputs. Also supply the custom image digest and `gpu_ami_id`. The latter must be an explicitly reviewed EKS AL2023 x86_64 NVIDIA AMI for the cluster minor version and the container’s CUDA/driver requirements. The standard CPU AL2023 AMI is unsuitable. Pinning avoids unplanned replacements when a new AMI appears.

Apply `workloads/` next. It installs Karpenter 1.8.1 and KEDA 2.18.1, then the EC2NodeClass/NodePool, then Triton, monitoring, and its ScaledObject. Custom resources are owned by small local Helm releases installed after their controller charts. This avoids `kubernetes_manifest` plan-time CRD discovery on a new cluster: `depends_on` alone cannot fix that provider behavior. Helm renders the resources at apply time and tracks their removal in state. The charts and IAM module are pinned reference versions, not promises that they are the latest release; review Kubernetes compatibility/security advisories when upgrading.

The NodeClass selects private subnets and the cluster security group by explicit IDs, uses IMDSv2, encrypted 200 GiB gp3 root disks at 6,000 IOPS/250 MiB/s, and tags GPU instances for optional SSM DCGM installation. Nodes inherit AL2023 bootstrap from Karpenter. Controller charts use CPU node selectors; expensive GPU nodes are tainted `nvidia.com/gpu=present:NoSchedule`. Triton, the image cache DaemonSet, NVIDIA device plugin, DCGM and Alloy tolerate this taint. The device plugin explicitly selects GPU workers and disables the chart’s default NFD-dependent affinity, so it does not require an uninstalled label-discovery service.

The NodePool allowlist is unordered. Karpenter can choose any eligible instance by availability and price; array order does not implement g7 → g6 → g5 preference. Strict preference would require weighted NodePools and separate pool limits. A single pool provides one shared GPU limit. Quota exhaustion is not guaranteed to trigger a successful fallback: multiple types can share the same quota. The default HPA limit is 10 and pool limit 11 GPUs, with one extra node for rolling replacement. Karpenter’s limits are eventually consistent and can briefly overshoot; they are capacity controls, not a hard dollar budget. Legacy managed GPU nodes are outside this limit.

G6 L4 and G5 A10G have 24 GB GPU memory, not identical 32 GiB GPUs. G5.4xlarge also has only 16 vCPUs/64 GiB host RAM; the existing Triton requests (8 CPU, 32 GiB RAM, one GPU) fit, unlike the suggested 28 CPU/110 GiB request. Validate weights, KV cache, architecture, NVIDIA driver and latency on every permitted instance and remove incompatible types from `gpu_instance_types`. Retaining `g7.8xlarge` from the original project is not a certification of its regional availability or model compatibility.

## Cold starts, model storage and termination

Triton uses `inference_stream_timeout_seconds + 30` seconds of termination grace (930 by default) and a 15-second preStop delay to allow endpoint removal before normal signal handling. Requests longer than the remaining grace can still be interrupted. Validate the bundled frontend’s signal handling with streaming requests before production. Rolling updates use one surge replica and zero unavailable; a PodDisruptionBudget keeps at least one available during voluntary node evictions. HPA pod deletions and forced cloud interruptions are not protected by a PDB.

Karpenter consolidates only empty nodes, avoiding live model movement for bin packing. Expiration is disabled; schedule and test AMI/security updates yourself. Drift or AWS events can still require replacements; the NodePool has a one-node voluntary disruption budget and a 15-minute node drain deadline. The HPA’s 15-minute stabilization affects reductions from N to one. KEDA’s `cooldownPeriod` affects zero transitions and is not a substitute for HPA scale-down stabilization.

The image cache DaemonSet warms the same digest on existing GPU nodes using `IfNotPresent`, without claiming a GPU. It cannot eliminate the download on a brand-new empty EC2 instance. For faster cold starts, build and validate an AMI with the exact image digest cached in containerd; neither this DaemonSet nor provisioning-time promises guarantee a sub-minute ready inference server. EC2 launch, image pull, EFS access, and GPU model initialization all contribute to readiness.

All replicas read shared weights from EFS but have a private emptyDir model repository. This prevents per-pod ConfigMap subPath mounts from interfering through shared EFS files. A shared atomic directory lock serializes initial archive downloads. An interrupted/forcibly killed init container can leave `/models/cache/.download-lock`; inspect running init containers and remove the lock only when no downloader owns it. Downloads time out rather than overwrite another replica’s archive. EFS shares files, not GPU memory: every replica loads its own selected model into its own GPU.

## Deployment and migration checklist

1. Build/publish the custom image, choose the tested NVIDIA AMI, configure the input examples, and back up existing Terraform state.
2. Apply infra to add system nodes, Karpenter IAM/access and interruption handling. On an existing installation, temporarily preserve existing GPU desired/minimum capacity while system nodes become ready.
3. Copy infra outputs and the image/AMI pins into workloads tfvars. Plan/apply workloads; allow up to 45 minutes for initial downloads and model loading. The API must be reachable from the Terraform operator.
4. Confirm custom metrics exist for the selected model, then confirm the ScaledObject/HPA and NodePool are ready. Run finite streaming load steps, watching the HPA, pending pods, NodeClaims, readiness and latency.
5. After verifying Karpenter-provisioned GPU nodes work, set legacy managed GPU desired/minimum to zero through infra. Plan the migration window: removing an existing managed GPU node can interrupt its active requests.
6. Commit `.terraform.lock.hcl` files after initialization and retain the base/custom image digests and tested AMI in your deployment records.

```sh
kubectl get nodes -L workload,karpenter.sh/nodepool
kubectl get nodepools,nodeclaims,ec2nodeclasses
kubectl -n karpenter logs deployment/karpenter --all-containers --tail=100
kubectl -n keda get pods
kubectl -n llm-serving get scaledobjects,hpa,pods
kubectl -n llm-serving describe scaledobject triton-vllm
kubectl -n llm-serving describe hpa keda-hpa-triton-vllm
kubectl -n llm-serving port-forward service/triton-vllm 8002:8002
# In another shell:
curl -fsS localhost:8002/metrics | rg 'llm_(kv_cache|num_requests|scheduler_update)'
```

Replace `llm-serving` with your configured namespace. In Prometheus, ensure one `triton-vllm` target per running replica, all `up=1`; inspect both generated trigger queries and timestamps. In Grafana, the existing profiling dashboard now includes KV usage and internal waiting requests per pod. Do not evaluate autoscaling through a single long-lived `kubectl port-forward service/...` connection: it selects a pod and does not balance each new request across replicas. Use the private HTTPS `inference_base_url` with a bearer key; the gateway discovers ready pods and selects an upstream per request, including reused client connections. Existing streams never migrate to a new pod.

## Failure modes, rollback and teardown

- **Missing/stale gauges:** inspect image digest, extension startup errors, selected-model labels and stats logging. The KEDA trigger reports errors instead of substituting zero. Do not disable the source/hash checks to make an upgrade pass.
- **Pending GPU pods:** inspect NodePool/NodeClass conditions, subnet IPs, regional instance availability, quotas, IAM events, GPU plugin health and the pinned AMI’s driver. Limits reserve only one surge node; additional drains can wait for capacity.
- **Controller outage:** restore CPU system capacity, DNS, IRSA/STS connectivity and controller health. Private nodes need NAT or appropriate VPC endpoints for AWS, registry and model downloads. KEDA’s aggregated metrics API and webhook must be reachable from the control plane; investigate security groups and port conflicts if external metrics fail.
- **Prometheus outage:** metric-driven scaling cannot calculate demand. There is no invented fallback signal; preserve/restore monitoring, and pause scaling if manual capacity is required.
- **Thrashing/latency:** tune bounds and thresholds using your traffic; account for long streams, per-pod request skew, cold-start duration and cache retention. An idle engine can retain prefix cache, so KV pressure alone may remain high. Tight maximum replicas caps that behavior; consider disabling prefix caching in the model configuration when cache retention dominates scaling signals.

For manual operation, set `paused_replicas = N` in workloads tfvars and apply (choose N no larger than `max_replicas`). This manages the ScaledObject’s `autoscaling.keda.sh/paused-replicas` annotation in Terraform. Set it to `0` for a deliberate serving suspension; set it back to `null` and apply to resume the minimum serving replica and autoscaling. Do not introduce a competing HPA. Restoring an older custom image requires restoring its matching extension/AMI/config and confirming readiness before removing healthy replicas.

Before destroying workloads, stop inference ALB clients, drain the API-key gateway, pause scaling, stop traffic, and scale the deployment to zero deliberately. While Karpenter is still running, delete the GPU NodePool and wait for every NodeClaim and EC2 GPU instance to terminate; back up EFS as needed. Then destroy workloads, followed by infra. Do not remove the Karpenter controller or its IAM role first: finalizers need the controller to terminate instances. `terraform destroy` alone cannot guarantee orderly draining of external EC2 resources created by Karpenter; inspect AWS for orphaned instances, volumes and load balancers. CPU system nodes, EKS, NAT, EFS and observability remain billable even when GPU capacity is zero.

## Validation and future upgrades

Run `python3 -m unittest discover -s tests -v` for CPU metrics contract tests. They cover fraction units, scheduler-only/idle callbacks, invalid/missing values and finalization. They are not a substitute for loading the actual image on a GPU. Before each Triton/vLLM upgrade, inspect the upstream logger factory, callback signature, scheduler fields and metric lifecycle; update the reviewed SHA only after that review, build the image, exercise a real model and streaming shutdown, and verify per-pod Prometheus series and HPA decisions under load. Repeat for each allowed GPU type and pinned NVIDIA AMI. Keep image provenance/scanning/signing in your registry release process.

Official references: [Triton backend](https://github.com/triton-inference-server/vllm_backend/tree/r26.04), [vLLM stat logger API and stability warning](https://github.com/vllm-project/vllm/blob/v0.19.0/vllm/v1/metrics/loggers.py), [KEDA Prometheus scaler](https://keda.sh/docs/2.18/scalers/prometheus/), [KEDA ScaledObject](https://keda.sh/docs/2.18/reference/scaledobject-spec/), [Karpenter NodePools](https://karpenter.sh/v1.8/concepts/nodepools/), [NodeClasses](https://karpenter.sh/v1.8/concepts/nodeclasses/), [Kubernetes HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/).
