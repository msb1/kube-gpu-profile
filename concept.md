# Concept: GPU LLM inference on EKS

## What this project builds

This project provisions a standard Amazon EKS cluster with an AWS-managed Kubernetes control plane and Karpenter-provisioned GPU workers plus a retained legacy managed GPU group. Terraform also creates a VPC, private worker subnets, NAT egress, EFS model cache, NVIDIA GPU scheduling, Triton with its vLLM backend, a Prometheus/Grafana/DCGM/Pyroscope observability stack, and a dedicated internal HTTPS inference ALB with an API-key gateway.

The GPU workers are **accelerated virtual EC2 instances**, not bare-metal servers. EKS still owns the control plane; AWS EC2 hosts the GPU worker nodes, and the NVIDIA EKS-optimized Amazon Linux 2023 AMI supplies the host driver/runtime pieces. The NVIDIA Kubernetes device plugin advertises `nvidia.com/gpu` to the scheduler. The Triton pod requests one GPU and therefore cannot start until a GPU worker is Ready.

The project uses two Terraform roots (`infra/` then `workloads/`). The first root builds AWS infrastructure; the second connects to the already-created cluster and installs Kubernetes resources. This makes the provider/bootstrap ordering explicit and avoids asking Kubernetes or Helm providers to operate before EKS exists.

## The serving path

```mermaid
flowchart LR
  Client -->|HTTPS and bearer API key| ALB[Dedicated internal inference ALB]
  ALB --> Gateway[API-key gateway pods]
  Gateway -->|Discover ready pods| Service[Headless Service: triton-backends]
  Service --> Frontend[NVIDIA OpenAI-compatible frontend]
  Frontend --> Triton[Triton In-process server]
  Triton --> Backend[vLLM backend / AsyncLLMEngine]
  Backend --> GPU[NVIDIA GPU]
  Triton --> Metrics[Triton Prometheus metrics /metrics via service port 8002]
  DCGM[DCGM exporter] --> Prom[Prometheus]
  Metrics --> Prom
  Prom --> Grafana
  Pyroscope[Pyroscope server] --> Grafana
  Init[Init container: HTTPS Bearer download] -->|three tar.gz archives| EFS[(Encrypted EFS cache)]
  EFS --> Triton
```

Artifactory stores one `tar.gz` archive for each model. On the first pod start, the init container downloads each archive using `Authorization: Bearer …` and extracts it to EFS. Later starts reuse the cache marker. The deployment presents three Triton model entries, but loads only `selected_model` at startup. The default GPU worker has one GPU; loading all three 7B/8B models simultaneously would overcommit its VRAM. Change the selected model and apply to switch models. EFS retains the archives across pod and node restarts.

Each archive must unpack the model's Hugging Face files directly into its archive root: `config.json`, tokenizer files, and weight shards such as `*.safetensors`. The wrapper creates the Triton repository and `model.json`; do not put another enclosing directory around the archive contents.

Model aliases used by the Terraform deployment:

| Alias | Intended artifact |
| --- | --- |
| `qwen25_7b_instruct` | Qwen2.5 7B Instruct |
| `qwen35_8b` | Qwen3.5 8B (archive/model architecture must be supported by the pinned vLLM in the Triton image) |
| `llama31_8b_instruct` | Llama 3.1 8B Instruct |

The archive URL map is configurable. Terraform does not infer JFrog repository keys or artifact naming conventions; supply the direct authenticated download URLs from your JFrog generic repository.

## Triton plus vLLM: who does what

NVIDIA's bundled OpenAI-compatible frontend starts the Triton server in-process and exposes OpenAI REST endpoints such as `/v1/models`, `/v1/completions`, and `/v1/chat/completions`. The frontend converts OpenAI requests for the vLLM backend. The Triton vLLM backend delegates LLM execution to vLLM's asynchronous engine; vLLM performs paged KV-cache management and inflight/continuous batching. Clients use a dedicated internal HTTPS ALB and API-key gateway. Terraform creates the gateway, certificate, validation/private DNS records and backend network policy. The gateway discovers ready Triton pods via a headless Service and selects an upstream for each new request; existing streams keep their original connection. See [inference.md](inference.md) for configuration and trust boundaries. [NVIDIA's OpenAI frontend documentation](https://github.com/triton-inference-server/server/tree/main/python/openai) and [vLLM backend documentation](https://github.com/triton-inference-server/vllm_backend) describe the components.

The backend is decoupled: one request may produce multiple streamed responses. Its model configuration must set `model_transaction_policy { decoupled: true }`. The OpenAI frontend translates chat/completions requests into the Triton vLLM backend's model inputs and handles streaming responses.

### PagedAttention

Autoregressive generation reuses key/value (KV) tensors from previous tokens. Reserving one large contiguous KV-cache region sized for the maximum output wastes memory when sequences have different lengths. PagedAttention divides a request's KV cache into fixed-size blocks and maps logical token positions to physical GPU blocks. vLLM allocates blocks as needed and can share prompt blocks for branching requests. This reduces fragmentation and allows concurrent sequences to make better use of limited GPU memory; it does not remove the memory cost of the model weights or KV cache.

### Continuous (inflight) batching

Traditional static batches wait for the longest request to finish, leaving slots idle when shorter sequences complete. Continuous batching updates the active batch at generation iterations: completed requests leave and queued requests can enter while other requests continue. This improves GPU occupancy under mixed prompt/output lengths. Paged KV blocks let vLLM add and remove active requests without relocating every other request's cache.

Together these mechanisms make a GPU serve concurrent requests more efficiently. Tune `gpu_memory_utilization` and `model_max_len` against actual context lengths and concurrency; raising context length increases KV-cache demand. The supplied `0.88` utilization is a starting point, not a guaranteed optimum.

## GPU sizing and cost model

Specifications below are for the requested single-GPU sizes. GPU memory is often quoted by vendors in decimal GB while tools report GiB; the distinction explains apparent differences.

| Instance | GPU | GPU memory | vCPU | Host RAM | Approx. on-demand Linux cost, us-east-1 |
| --- | --- | ---: | ---: | ---: | ---: |
| `g7.8xlarge` (preferred) | 1× NVIDIA RTX PRO 4500 Blackwell Server Edition | 32 GiB | 32 | 128 GiB | about $4.09/hour; about $2,983 for 730 hours |
| `g6.8xlarge` | 1× NVIDIA L4 | 24 GB | 32 | 128 GiB | about $2.18/hour; about $1,595 for 730 hours |
| `g5.4xlarge` | 1× NVIDIA A10G | 24 GB | 16 | 64 GiB | about $1.62/hour; about $1,186 for 730 hours |

AWS's current [EC2 accelerated-instance specification table](https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html) lists `g7.8xlarge` with a 32 GiB RTX PRO 4500 GPU. The approximate cost figures are a us-east-1 Linux on-demand snapshot from [CloudParity's G7 page](https://cloudparity.io/pricing/aws/g7.8xlarge), [EC2Info's G6 page](https://ec2info.app/g6.8xlarge), and [CloudParity's G5 page](https://cloudparity.io/pricing/aws/g5.4xlarge); check the AWS Pricing Calculator for your account, region, and purchase option before deployment. Availability, quotas, capacity, and actual rates vary by region and AZ. Set `gpu_instance_type` in `infra/terraform.tfvars` to choose an alternative.

The GPU node is only one part of the bill. Also estimate the EKS cluster-hour charge, NAT Gateway hours and data, EFS storage/throughput, CloudWatch control-plane logs, public IPv4 addresses, image/model data transfer, and Prometheus storage. A continuously running GPU node dominates cost; KEDA and Karpenter reduce replicas and GPU nodes when demand falls, retaining one serving replica. For a complete manual stop, pause scaling and scale serving to zero, then let Karpenter reclaim empty nodes; serving is unavailable until explicitly restarted. CPU system nodes and other AWS services remain billable. See [autoscaling.md](autoscaling.md).

The `g7.8xlarge` has the most VRAM of the three listed choices and is the configured default. For cost-sensitive development, G5 or G6 can run many 7B/8B models at quantized or reduced context settings, subject to the model's actual memory footprint. Start with one selected model and validate workload performance before increasing concurrency or adding GPUs.

## Observability and profiling

- **DCGM exporter** exposes NVIDIA device telemetry such as utilization, memory, temperature, and power, plus explicitly selected tensor-pipe, SM-active, DRAM-active, and FP16-pipe profiling series. The counters are interval averages; some fields can be unsupported or unavailable on a particular GPU/driver, and collecting them may multiplex hardware counter groups.
- **Triton metrics** expose inference counts/latencies, GPU/CPU telemetry, and (with the vLLM backend custom metrics switch) token and time-to-first-token statistics. Prometheus scrapes `/metrics` through service port 8002. See [Triton metrics](https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/user_guide/metrics.html) and the [vLLM backend metrics notes](https://github.com/triton-inference-server/vllm_backend).
- **Prometheus and Grafana** collect and visualize those metrics. The stack includes a community NVIDIA DCGM dashboard as a starting point.
- **Pyroscope plus Grafana Alloy eBPF** provide continuous CPU profiling for processes in the Triton pod on GPU workers. Alloy requires host PID access and privileged/root access for eBPF; the DaemonSet is restricted to the GPU node pool and relabels to Triton. This profiles CPU stacks, not CUDA kernels or GPU memory. DCGM supplies GPU hardware telemetry. For CUDA-kernel profiling, use NVIDIA Nsight Systems/Compute separately.

Grafana is reached through its separate internal, CIDR-restricted ALB over a VPN/private route. Inference uses a different internal ALB with HTTPS and bearer-key authentication.

### How Pyroscope collects and uses profiles

[The observability configuration](workloads/observability.tf) installs a Pyroscope server and an Alloy DaemonSet. Alloy runs on nodes labeled `workload=gpu-inference`, discovers local pods and processes every 15 seconds, and selects processes in the configured workload namespace whose pod has the label `app=triton-vllm`. Its eBPF profiler samples their CPU call stacks and forwards profiles to Pyroscope on port 4040. Grafana is configured with a Pyroscope data source and the Pyroscope app.

The profiler records sampled stacks: functions executing when samples are taken, their callers, and their relative share of sampled CPU time. Depending on runtime support and available symbols, profiles can include Python and native frames. Target-derived labels help identify profiles; inspect the labels and service names available in Grafana. The configuration does not explicitly set the sampling or collection intervals. Current Alloy documentation lists defaults of 19 samples per second and a 15-second collection interval; effective defaults depend on the deployed Alloy version. See the [Alloy eBPF reference](https://grafana.com/docs/alloy/latest/reference/components/pyroscope/pyroscope.ebpf/).

These CPU profiles can identify host-side work such as tokenization, Python code, or native library execution when the corresponding frames are resolved. They do not show CUDA kernel execution, GPU memory profiles, per-request traces, or memory-allocation and lock-contention profiles. Sampled CPU stacks alone cannot explain time spent waiting for the GPU or network. DCGM and Prometheus provide the separate GPU hardware metrics.

To explore profiles:

1. Connect to the VPC over VPN or another private route. From the `workloads` directory, run `terraform output -raw grafana_internal_alb_hostname`.
2. Open `http://<hostname>/` and sign in as `admin` with the password supplied through `TF_VAR_grafana_admin_password`.
3. Open **Profiles Drilldown**, or open **Explore** and select the **Pyroscope** data source. Select the available Triton service and CPU profile, and choose a time range when inference was running.
4. Inspect the flame graph: wider frames represent a greater share of sampled CPU time. Follow the stack through its callers and compare a quiet period with a load-test period or two different load levels. Profiles Drilldown supports comparison and differential flame graphs; see [Grafana's profile exploration guide](https://grafana.com/docs/pyroscope/latest/view-and-analyze-profile-data/pyroscope-ui/).
5. Compare the same interval with the **LLM GPU Macro Profiling** dashboard. For example, high CPU time in preprocessing alongside low GPU utilization can suggest a host-side bottleneck, which the profile can help investigate.

If profiles are missing, check that Triton is running and receiving work, then inspect the observability pods and Alloy logs:

```bash
kubectl -n observability get pods
kubectl -n observability logs daemonset/alloy-ebpf-profiler --tail=100
```

## Security model

The JFrog token is a Kubernetes Secret read by the init container. Terraform marks its input sensitive, which redacts normal CLI display, but the value is still present in Terraform state and Kubernetes API storage. Use a remote state backend with encryption, restricted IAM access, and locking; enable EKS secret encryption appropriate to your security requirements; rotate the token and Grafana password; and avoid shell history, checked-in `.tfvars`, or CI logs. The `.gitignore` excludes tfvars and state files.

The EKS public API endpoint is restricted by `admin_cidr_blocks`; replace the example default with a trusted VPN/office CIDR before apply. GPU nodes use private subnets with NAT egress. Triton pods remain private behind the API-key gateway and internal HTTPS inference ALB. Follow least privilege for the Terraform operator and production IAM roles.

## Autoscaling inference capacity

This implementation couples KEDA (a Prometheus metrics adapter/operator that creates an HPA) with Karpenter (a pending-pod-driven EC2 provisioner). HPA adjusts serving replica count; each replica requests one GPU and causes a new node to be provisioned when no existing GPU is free. The custom Triton image reports actual scheduler KV-cache usage and waiting work. CPU or framebuffer usage alone does not capture KV pressure. The two independent triggers allow either pressure to increase capacity, while a 15-minute scale-down window reduces expensive model reloads. Read [autoscaling.md](autoscaling.md) for units, formulas, defaults and limitations.
