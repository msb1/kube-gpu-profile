# EKS GPU LLM inference and profiling

Terraform for a small LLM serving environment on AWS: a managed EKS control plane, GPU EC2 worker nodes, NVIDIA Triton with the vLLM backend and NVIDIA's OpenAI-compatible `/v1` frontend, JFrog Artifactory model archives cached on encrypted EFS, and Prometheus/Grafana/DCGM/Pyroscope observability.

The preferred worker is `g7.8xlarge` (one 32 GiB GPU, 32 vCPU, 128 GiB RAM); use `g6.8xlarge` or `g5.4xlarge` when region capacity, quotas, or budget call for them. G-series are GPU-accelerated EC2 instances, not bare-metal hosts. This deployment intentionally loads one selected model at a time on its single-GPU default node while caching all three model archives.

## Start here

1. Read [concept.md](concept.md) for GPU/LLM serving fundamentals and sizing.
2. Read [architecture.md](architecture.md) for resource design, trust boundaries, and telemetry paths.
3. Follow [operation.md](operation.md) for prerequisites, configuration, deployment, validation, model switching, scaling, and teardown.
4. Copy the Terraform example files and fill in local values. Keep secrets out of `.tfvars` and source control.
5. Use [stress.md](stress.md) to benchmark the active model through the private Triton service and monitor GPU utilization.

Terraform is split into two roots because the Kubernetes and Helm providers require an existing, reachable EKS API and joined GPU node:

```text
infra/       VPC, EKS, GPU managed node group, IAM, EFS
workloads/   EFS PV/PVC, Artifactory download, Triton/vLLM, monitoring charts
```

The workloads root also installs AWS Load Balancer Controller and an internal ALB for Grafana. Configure the ALB allowlist (`grafana_ingress_cidrs`) for your VPN/private network and connect to the VPC to open the hostname from the Terraform output. The starter listener is HTTP-only; use private ACM TLS before production.

## Observability

The workloads Terraform root provisions Prometheus, Grafana, Pyroscope, Grafana Alloy, and NVIDIA DCGM Exporter. Prometheus uses the repository's [scrape configuration](workloads/prometheus.yml) to collect Triton/vLLM backend metrics and DCGM hardware telemetry. The provisioned **LLM GPU Macro Profiling** Grafana dashboard shows GPU utilization and memory, tensor/SM/DRAM/FP16 profiling counters, vLLM token throughput, and supported TTFT/TPOT metrics. Grafana is accessed through the internal, CIDR-restricted ALB over VPN or private networking; it does not require `kubectl port-forward`.

Pyroscope with Alloy provides host CPU profiling for Triton; it does not profile CUDA kernels. The infra root has an optional SSM-managed DCGM host CLI/engine mode for terminal diagnostics; both Terraform flags must be enabled together. See [architecture.md](architecture.md) for the telemetry path and [operation.md](operation.md) for deployment and access instructions. The current Triton vLLM integration does not forward KV-cache usage or preemption counters, so Grafana cannot directly show those values in this configuration.

## Stress testing

The repository includes several ways to load-test the active model through its private OpenAI-compatible `/v1` endpoint:

- [Locust capacity test](tools/locust-capacity/locustfile.py): SSE-aware virtual-user traffic with a configurable step-load shape. It records TTFT to the first text delta and full request latency; SSE chunk spacing is reported as an approximation, not token-level ITL. The detailed run instructions use the Python environment in `~/Code/rag-bench` and include guidance for interpreting virtual users versus in-flight requests.
- [vLLM serving benchmark](tools/stress/upstream/vllm/benchmarks/serve.py): random synthetic prompts; no ShareGPT dataset download is required.
- NVIDIA GenAI-Perf source and usage notes are included under `tools/stress/upstream/triton-perf-analyzer/genai-perf/`.

See [stress.md](stress.md) for connection setup, commands, progressive load profiles, Grafana/Prometheus metrics to watch, and capacity evaluation. The serving API remains private; run the client from an approved private-network location or use the documented temporary port-forward for the API.

## Model archives and credentials

Provide a direct HTTPS `tar.gz` download URL for each alias in the workloads tfvars file. Each archive should have Hugging Face model and tokenizer files directly at its root. The init container downloads with `Authorization: Bearer …` and caches the extracted assets on EFS. Supply `TF_VAR_artifactory_token` and `TF_VAR_grafana_admin_password` through your shell or secret store. Terraform state contains these secret values; use encrypted, access-controlled state storage.

The selected model names are `qwen25_7b_instruct`, `qwen35_8b`, and `llama31_8b_instruct`. Confirm the vLLM version bundled in the Triton image supports your exact model artifact, especially Qwen3.5 8B, before a production rollout.

## Design notes

- AWS manages the Kubernetes control plane. Terraform manages the VPC, EKS configuration, EKS managed GPU node group and EFS.
- Triton's bundled OpenAI-compatible frontend serves `/v1/models`, `/v1/completions`, and `/v1/chat/completions` through a private ClusterIP Service. Grafana is reachable through an internal, CIDR-restricted ALB managed by AWS Load Balancer Controller; connect through a VPN/private network into the VPC. Port forwarding is only used for temporary inference API checks.
- vLLM provides PagedAttention and continuous/inflight batching inside the Triton server. Triton provides model serving endpoints and metrics.
- DCGM supplies GPU hardware telemetry; Triton exposes inference and GPU metrics; Prometheus/Grafana collect and display them.
- Optional: set `install_dcgm_cli = true` in `infra/terraform.tfvars` and `use_host_dcgm_engine = true` in `workloads/terraform.tfvars` to install a driver-compatible DCGM CLI/host engine through SSM and connect the exporter to it. See [operation.md](operation.md); the default uses the exporter’s embedded engine.
- Pyroscope with Grafana Alloy eBPF profiles Triton CPU stacks on the GPU node. The profiler requires a privileged host-PID DaemonSet; it does not profile CUDA kernels. DCGM handles GPU telemetry; use NVIDIA Nsight for kernel-level profiling.
- Costs vary with region and current pricing. The continuously running GPU node is the largest line item; see the sizing table in [concept.md](concept.md).
