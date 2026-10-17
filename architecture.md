# Architecture and Terraform implementation

## Resource layout

```text
infra/                         AWS infrastructure Terraform root
  versions.tf                  AWS and TLS provider pins
  variables.tf                 Region, network, EKS, GPU sizing, operator access
  network.tf                   VPC, 3 public/private AZ subnets, IGW, NAT, EFS
  eks.tf                       EKS control plane, IAM/IRSA, access, add-ons, GPU node group
  outputs.tf                   Values consumed by the workloads root
  terraform.tfvars.example     Non-secret example values

workloads/                     Kubernetes/Helm Terraform root
  versions.tf                  AWS, Kubernetes and Helm providers
  variables.tf                 Cluster/EFS inputs, model URLs, model choice, secrets
  models.tf                    EFS PV/PVC, Artifactory pull, Triton and Service
  observability.tf             NVIDIA plugin/DCGM, Prometheus/Grafana, Pyroscope
  prometheus.yml               Prometheus Triton/vLLM and DCGM scrape jobs
  dashboards/llm-gpu-profiling.json
                               Provisioned Grafana GPU profiling and KV-cache panels
  terraform.tfvars.example     Model artifact URLs and non-secret inputs

concept.md                     Background and design decisions
operation.md                   Deploy, operate, switch, scale and tear down
architecture.md                This document
README.md                      Entry point
```

## Deployment sequence

1. **VPC:** Create a dedicated VPC with three public and three private subnets across available AZs, an Internet Gateway, a single NAT Gateway, and subnet route tables. The single NAT is a cost-conscious starting topology; it is an AZ-level dependency and may incur cross-AZ data costs. For production resilience, use one NAT per AZ or VPC endpoints where suitable.
2. **EKS control plane:** Create a standard managed EKS cluster, private and restricted public API access, control-plane logging, operator access entry, IAM role and core networking add-ons.
3. **Worker and persistent storage:** Create an EKS managed node group on private subnets with the NVIDIA AL2023 AMI and one configurable G-series EC2 type. The node group supplies an Auto Scaling group and lifecycle management. Create encrypted EFS, mount targets and security group; install the EFS CSI EKS add-on with IRSA.
4. **Workloads root:** Configure AWS auth against the cluster only after infra apply completes. Install NVIDIA's device plugin, DCGM exporter, Pyroscope, and kube-prometheus-stack. Create the static EFS PV/PVC. Triton's init container downloads the three archive URLs into EFS; Triton is scheduled only after a GPU resource is advertised and starts the configured selected model.

Terraform's graph orders resources inside each root. The separate apply boundary is deliberate: Terraform provider initialization cannot reliably wait for resources in the same configuration to make a newly created cluster/API endpoint and joined nodes ready. The workload root also sets explicit dependencies for the device plugin, storage claim, and monitoring components.

## GPU node pool and AMI

The managed node group is not bare metal. It is an EC2 accelerated instance group registered to the AWS-managed EKS control plane. The default is `g7.8xlarge`; alternatives are set through `gpu_instance_type`. The node group has `gpu_min_size`, `gpu_desired_size`, and `gpu_max_size` variables. The default desired and maximum sizes are one GPU node, sufficient for one active selected model. Increase capacity only after testing memory, cost, and scheduling. A pod requesting `nvidia.com/gpu: 1` is scheduled only when the NVIDIA device plugin advertises a free GPU.

The GPU worker role includes `AmazonSSMManagedInstanceCore` for IAM-controlled Systems Manager Session Manager access. Nodes remain private, with no inbound SSH rule or SSH key pair. The private-subnet NAT route provides outbound SSM connectivity. An opt-in SSM State Manager association (`install_dcgm_cli`) detects the installed CUDA user-mode version, installs the matching NVIDIA DCGM package, and starts the host engine. When enabled, the workloads root's `use_host_dcgm_engine` flag configures DCGM Exporter to connect to that host engine; keep the flags aligned. The default remains the exporter's embedded engine and does not install host packages.

The AL2023 NVIDIA EKS AMI includes the host driver, CUDA user-mode driver, and NVIDIA Container Toolkit; the NVIDIA device plugin remains a cluster add-on for this managed node group. AWS recommends DRA for some newer Kubernetes configurations, but this deployment uses the mature `nvidia.com/gpu` device-plugin resource interface for compatibility. See [AWS EKS GPU device management](https://docs.aws.amazon.com/eks/latest/userguide/device-management-nvidia-dra-device-plugin.html).

## Storage and model repository

EFS is encrypted and mounted read/write by the Triton pod. The CSI driver uses IRSA for AWS API operations. A static persistent volume refers to the filesystem ID; it retains downloaded model assets independently of the pod. EFS throughput, storage size, backup policy, and lifecycle policy should be sized and governed for the organization's workload.

The init container reads three direct HTTPS URLs and a bearer token from a Kubernetes Secret. It downloads each archive only when its `.download-complete` marker is absent. If an archive changes at the same URL, delete its marker/cache directory or use a versioned immutable URL. For production supply checksums and verify them before extraction. The model archive should contain the HF model files at its root; the model repository and `model.json` are generated by Terraform.

The selected-model flag uses Triton's explicit model control: all three models are described in the model repository but only one is loaded at startup. Switching the selected model changes the deployment and reloads Triton; it is a brief service interruption. Do not set Triton replicas above one against one shared GPU unless GPU partitioning/sharing and model memory have been deliberately designed. EFS allows multiple pods to read the same weights but does not create GPU memory.

## Inference and request path

The `triton-vllm` pod runs NVIDIA's bundled OpenAI-compatible frontend, which starts an in-process Triton server and routes OpenAI requests into the selected vLLM backend model. It uses the model's tokenizer from the same EFS-cached archive. The `triton-vllm` ClusterIP Service exposes:

| Port | Protocol | Use |
| ---: | --- | --- |
| 8000 | HTTP | OpenAI-compatible API (`/v1/models`, `/v1/completions`, `/v1/chat/completions`) and readiness endpoint; targets container port 9000 |
| 8002 | HTTP | Triton metrics endpoint (`/metrics`) on the in-process Triton server; includes native vLLM custom metrics when enabled |

The vLLM Triton backend expects decoupled model transactions and uses `model.json` as vLLM engine arguments. The model config enables custom vLLM metrics. Streaming chat completions are supported by the frontend/backend combination. The inference service remains ClusterIP-only; API key authentication, ingress, rate limits, and external TLS termination are not configured. **Production must add and enforce API-key authentication for inference requests**, including cluster-internal clients, before enabling production use. Manage keys in a secret manager, rotate them, and never commit them in Terraform files.

Grafana is exposed separately through an internal Application Load Balancer. The AWS Load Balancer Controller is installed by the workloads root and assumes a dedicated IRSA role created by the infra root. The ALB allows only the configured `grafana_ingress_cidrs`; access requires VPN or another private route into the VPC. The starter listener is HTTP-only, suitable only for a trusted private network. Production should use HTTPS with a private ACM certificate and a private DNS name.

## Telemetry data path

- `workloads/prometheus.yml` is the source of the additional scrape jobs passed to kube-prometheus-stack. Terraform renders the configured Kubernetes namespace into this file before Helm installation.
- The `triton-vllm` job scrapes `triton-vllm.<namespace>.svc.cluster.local:8002/metrics`. This is the in-process Triton server's metrics endpoint and includes Triton metrics plus the vLLM metric subset forwarded by the backend (prompt/generation tokens, TTFT, time-per-output-token, end-to-end latency, and request-parameter histograms). The Triton backend currently does not list standalone vLLM KV-cache usage or preemption metrics.
- The `dcgm-exporter` job discovers pods in `observability`, selects the NVIDIA DCGM exporter, and scrapes port 9400. Its Terraform-managed custom collector includes GPU utilization/memory plus tensor, SM-active, DRAM-active, and FP16 profiling metrics; Grafana provisions a dedicated LLM GPU profiling dashboard for these fields.
- kube-prometheus-stack supplies Prometheus, Grafana, alerting components, node exporter, and Kubernetes metrics integrations.
- Pyroscope stores profile data and is configured as a Grafana datasource. A Grafana Alloy eBPF DaemonSet runs as root with host PID access on GPU nodes and filters its discovered targets to the Triton pod. This provides software CPU profiles and requires elevated host access. DCGM is the GPU hardware telemetry path; Pyroscope/eBPF is not a GPU kernel profiler.

Prometheus and Grafana persistence/retention should be explicitly sized for production. Grafana is exposed through an internal ALB created by AWS Load Balancer Controller and restricted to `grafana_ingress_cidrs`; reach it through a VPN or private connection into the VPC. The starter ALB listener uses HTTP, so configure a private ACM certificate and HTTPS listener before using untrusted networks. The current chart configuration uses short Prometheus retention and chart defaults for small-scale evaluation. Consider EBS-backed PVCs, backups, authentication integration, retention, and alert destinations before production.

## Trust boundaries and secrets

- AWS authentication is the local AWS CLI/profile/role used by Terraform; no long-lived AWS keys belong in `.tfvars`.
- EKS API access uses the declared IAM `cluster_admin_arn` access entry and the operator's AWS credentials.
- JFrog authorization is sent only by the init container to the provided HTTPS artifact URLs.
- Terraform's `sensitive` marker only redacts output. The token is stored in Terraform state and as a Kubernetes Secret. Treat both state and cluster API data as secret-bearing, encrypt and restrict them, and rotate credentials.
- The public EKS API is restricted by `admin_cidr_blocks`; nodes and Triton remain private. Do not change the inference Service to LoadBalancer or add public ingress without an explicit authentication and TLS design.

## Operational failure points

| Symptom | Likely cause |
| --- | --- |
| GPU node group does not create | G-series On-Demand quota/capacity or AZ availability; select an alternate type or region, request quota, and re-plan. |
| Node is Ready but GPU pod remains Pending | NVIDIA device plugin has not registered a GPU; check plugin DaemonSet, node AMI, allocatable resource, and node selector. |
| EFS PVC is Pending or mount fails | EFS CSI add-on/IRSA, NFS 2049 rule, EFS mount target, subnet routing, or filesystem ID. |
| Artifactory init container fails | URL path, bearer token scope/expiry, TLS trust, archive format/size, or private Artifactory network reachability from private subnets. |
| Triton reports model initialization error | Archive root layout, tokenizer/weight files, unsupported model architecture or quantization, vLLM/image incompatibility, or insufficient GPU memory/context configuration. |
| OpenAI frontend fails to start | Check that the Triton image contains `python/openai/openai_frontend/main.py`, required frontend dependencies, and a valid local tokenizer directory in the selected archive. |
| Prometheus has no GPU series | DCGM exporter scheduling/driver compatibility, scrape discovery labels/ports, or exporter chart issue. |
| Prometheus has no vLLM series | Confirm the `triton-vllm` target is `UP`, the Triton service exposes port 8002, and the selected vLLM backend has initialized and is emitting metrics at `/metrics`. |
| Grafana ingress has no ALB hostname | Check the AWS Load Balancer Controller pod/logs, its IRSA role permissions, ingress events, private subnet tags, target health, and `grafana_ingress_cidrs`. |

The default Triton tag is `26.04-vllm-python-py3`, which bundles vLLM 0.19 and requires a sufficiently recent NVIDIA driver (CUDA 13.2 / driver 595.58.03 in NVIDIA's compatibility matrix). This is chosen to align with current EKS NVIDIA AL2023 AMIs that bundle the R595 driver line while supporting newer model architectures. Check the actual selected AMI driver and Triton [compatibility matrix](https://github.com/triton-inference-server/server/blob/main/docs/introduction/compatibility.md) before applying. Validate the exact model architecture (in particular `qwen35_8b`) against the vLLM version and exact archive before production. A service can deploy successfully while a model fails to load if its architecture is unsupported.
