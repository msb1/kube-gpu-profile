# Operations guide

## Prerequisites

- Terraform 1.6+, AWS CLI, `kubectl`, and Helm installed locally. Terraform's Kubernetes and Helm providers use the AWS CLI exec credential plugin to refresh EKS tokens during longer applies.
- AWS credentials configured for an IAM principal allowed to create VPC, EKS, EC2, EFS, IAM/OIDC, CloudWatch, and related resources.
- For direct GPU worker diagnostics, an operator IAM principal with permission to start SSM Session Manager sessions on the GPU EC2 instance (and the Session Manager plugin installed locally). The private nodes reach SSM through the Terraform-managed NAT gateway.
- An IAM **user or role ARN** for `cluster_admin_arn` (not an STS assumed-role session ARN).
- AWS service quotas and GPU On-Demand capacity for the selected instance type and region.
- Three Artifactory generic-repository HTTPS download URLs, each returning one `tar.gz` archive with Hugging Face files in its archive root.
- A JFrog token authorized to read those artifact paths; a separate Grafana initial admin password.
- If JFrog uses a private certificate authority, the PEM CA certificate can be supplied as `artifactory_ca_certificate` in the workloads tfvars file; this is a public certificate, not a private key.
- If NGC requires authenticated image pulls for your account, an NGC API key (optional `TF_VAR_ngc_api_key`).

## Configure

Copy both example files and edit them. These files are ignored by Git.

```sh
cp infra/terraform.tfvars.example infra/terraform.tfvars
cp workloads/terraform.tfvars.example workloads/terraform.tfvars
```

In `infra/terraform.tfvars`, set a secure API CIDR, the IAM role/user ARN, region, and instance choice. `g7.8xlarge` is the default; if unavailable, choose `g5.4xlarge` or `g6.8xlarge`. Check the region's GPU quotas and availability before spending time on apply.

In `workloads/terraform.tfvars`, set `cluster_name`, `aws_region`, `vpc_id`, `efs_file_system_id`, `aws_load_balancer_controller_role_arn`, `grafana_ingress_cidrs`, and the three direct archive URLs. The role ARN and VPC ID are outputs from the infra root. Set the CIDR list to the trusted VPN/private client networks that need Grafana access. Do not put JFrog or Grafana passwords in this file. Export Terraform input variables in your shell or CI secret store instead:

```sh
export TF_VAR_artifactory_token='your-jfrog-token'
export TF_VAR_grafana_admin_password='use-a-unique-long-password'
# Optional, if nvcr.io requires authentication:
export TF_VAR_ngc_api_key='your-ngc-api-key'
```

Terraform's `sensitive = true` masks normal output; it does **not** keep credentials out of Terraform state. Use encrypted remote state with strict access and locking for shared/production use. Avoid terminal recording and CI debug logs.

## Deploy infrastructure

```sh
cd infra
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Save these outputs for the workloads root:

```sh
terraform output -raw cluster_name
terraform output -raw aws_region
terraform output -raw efs_file_system_id
terraform output -raw vpc_id
terraform output -raw aws_load_balancer_controller_role_arn
```

Configure `workloads/terraform.tfvars` with those values, including `grafana_ingress_cidrs` set to the trusted VPN/private network CIDRs that should reach the internal Grafana load balancer. Then configure kubectl. From the `infra/` directory:

```sh
aws eks update-kubeconfig --region "$(terraform output -raw aws_region)" --name "$(terraform output -raw cluster_name)"
kubectl get nodes -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu
```

Wait until the GPU node is `Ready` and reports one allocatable GPU. The workload provider root cannot be applied from a machine/network that cannot reach the EKS public endpoint. Restrict `admin_cidr_blocks` to the current trusted egress CIDR; use VPN or a controlled runner.

### Secure GPU worker shell (optional)

The GPU node role includes `AmazonSSMManagedInstanceCore`. Use Systems Manager Session Manager for an audited, IAM-authorized shell: this stack opens no inbound SSH port and does not create or distribute a key pair. Grant the operator least-privilege `ssm:StartSession` access to the intended instance and `ec2:DescribeInstances`; do not grant broad SSM access if instance-scoped access is sufficient. The operator must also be authorized to use the Session Manager plugin. Find the worker instance and start a session:

```sh
NODE_PROVIDER_ID=$(kubectl get nodes -l workload=gpu-inference -o jsonpath='{.items[0].spec.providerID}')
GPU_INSTANCE_ID=${NODE_PROVIDER_ID##*/}
aws ssm start-session --region "$(terraform output -raw aws_region)" --target "$GPU_INSTANCE_ID"
```

To install the host DCGM CLI and engine automatically, set `install_dcgm_cli = true` in `infra/terraform.tfvars` **and** `use_host_dcgm_engine = true` in `workloads/terraform.tfvars` before applying either root. Apply `infra` first, then `workloads`. The SSM State Manager association detects the NVIDIA driver's CUDA user-mode major version with `nvidia-smi`, installs the matching `datacenter-gpu-manager-4-cuda<major>` package from NVIDIA's Amazon Linux 2023 CUDA repository, enables `nvidia-dcgm`, and verifies GPU discovery. It runs when the association is created and daily; the tag target picks up replacement nodes. This option uses the host DCGM engine; the workloads root configures DCGM Exporter to connect to `127.0.0.1:5555` using host networking. Keep the two flags aligned: enabling the exporter connection without installing the host engine will leave the exporter unable to collect metrics. Disabling the option later returns the exporter to embedded mode but does not automatically uninstall DCGM from existing nodes.

Confirm the SSM association completed in Systems Manager **State Manager → Associations** before relying on the CLI. Then open the SSM shell above and run:

```sh
dcgmi discovery -l
dcgmi dmon
```

NVIDIA's package selection is based on the installed CUDA user-mode version; see the [DCGM Amazon Linux 2023 installation instructions](https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/getting-started.html#amazon-linux-2023). For a cluster already serving traffic, plan a maintenance window when switching the exporter between embedded and host-engine modes.

## Deploy Kubernetes workloads

From the repository root, fill the output values into `workloads/terraform.tfvars`, then:

```sh
cd workloads
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

First start can take a long time because all three archives are downloaded and unpacked to EFS. Follow progress:

```sh
kubectl -n llm-serving get pods -w
kubectl -n llm-serving logs deploy/triton-vllm -c artifactory-model-cache
kubectl -n llm-serving logs deploy/triton-vllm -c triton -f
kubectl -n observability get pods
```

Verify GPU allocation and OpenAI frontend readiness. The inference service exposes OpenAI-compatible HTTP on port 8000 and Triton metrics (including enabled vLLM custom metrics) on port 8002; it remains a private ClusterIP. Terraform also creates a private ALB for Grafana, restricted to `grafana_ingress_cidrs`.

```sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu
kubectl -n llm-serving port-forward svc/triton-vllm 8000:8000 8002:8002
```

In another terminal:

```sh
curl -fsS http://127.0.0.1:8000/health/ready
curl -fsS http://127.0.0.1:8000/v1/models
curl -fsS http://127.0.0.1:8002/metrics | grep -E 'nv_gpu|vllm:' | head
curl -sS http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25_7b_instruct","messages":[{"role":"user","content":"Explain PagedAttention in one sentence."}],"temperature":0.2,"max_tokens":128,"stream":false}'
```

The OpenAI-compatible frontend is launched from the pinned Triton `26.04-vllm-python-py3` image and uses the selected model's tokenizer from `/models/cache/<selected_model>`. Confirm that the image contains the frontend and that the bundled vLLM supports each artifact architecture before serving traffic. Also confirm the GPU node's NVIDIA driver meets the image's CUDA driver minimum. The EKS NVIDIA AMI is updated independently of the Triton image.

The `model` field must match the active `selected_model`. The Grafana ALB is private: connect your workstation to the VPC through the organization's VPN or another approved private network path. The ingress's CIDR allowlist must include that trusted client network. After workload apply, get the ALB hostname with:

```sh
terraform output -raw grafana_internal_alb_hostname
kubectl -n observability get ingress grafana
```

The hostname resolves and connects only from the VPC or a connected network. Open `http://<hostname>/` and sign in as `admin` using the password supplied through `TF_VAR_grafana_admin_password`. The ALB is internal and HTTP-only in this starter configuration; use a private ACM certificate and HTTPS listener for production access across networks that are not fully trusted.

Workloads inside the cluster should configure their OpenAI client with `base_url = "http://triton-vllm.llm-serving.svc.cluster.local:8000/v1"` and set `model` to the active alias. The frontend does not enforce API-key authentication; only workloads with cluster network access can reach the private ClusterIP, so add an authenticated ingress/gateway before exposing it beyond the cluster.

**Production requirement:** configure and enforce API-key authentication for inference requests before production use, including clients that reach the service from inside the cluster. Keep keys in a secret manager, rotate them, and do not place them in Terraform source or checked-in tfvars. The current starter deployment leaves this enforcement unconfigured.

Check Prometheus targets and the NVIDIA DCGM dashboard. The Terraform-managed `workloads/prometheus.yml` scrapes the Triton metrics endpoint on Service port 8002, including the vLLM subset forwarded by the backend, and `dcgm-exporter` hardware/profiling metrics on port 9400. In Prometheus, open **Status → Targets** and confirm both jobs are `UP`. Useful queries include `vllm:prompt_tokens_total`, `vllm:time_to_first_token_seconds_count`, and `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`; metric availability can vary by backend/GPU support. The current Triton vLLM backend does not expose vLLM KV-cache usage or preemption metrics through its documented custom metrics set. Alloy eBPF profiles CPU stacks from the Triton process; use Grafana's Profiles Drilldown and select the Triton service/profile type. These are CPU profiles, not CUDA kernel profiles.

## Switch the active model

Set `selected_model` in `workloads/terraform.tfvars` to one of:

```hcl
selected_model = "qwen25_7b_instruct"
# selected_model = "qwen35_8b"
# selected_model = "llama31_8b_instruct"
```

Then run `terraform plan` and `terraform apply` in `workloads/`. The Triton OpenAI frontend restarts and loads the chosen model. The service has one replica and there will be an inference interruption during the switch. All archives remain cached on EFS. If replacing an archive at a URL, remove `/models/cache/<alias>/.download-complete` (and stale contents) from EFS before restarting, or use a new immutable URL.

## Scale GPU capacity

Change `gpu_desired_size` and `gpu_max_size` in `infra/terraform.tfvars`, then apply the infra root. One replica requesting one GPU uses one node. Additional nodes provide scheduling capacity but Terraform does not create extra Triton replicas automatically. If replicating Triton, each replica loads its own model into its own GPU and raises the hourly EC2 bill. EFS shares files, not GPU memory.

To stop GPU spending when idle, set `gpu_desired_size = 0` and `gpu_min_size = 0`, then apply infra. Triton remains pending/unavailable until GPU capacity returns. EKS, NAT, EFS, logs and observability may continue to incur charges.

## Secrets and state handling

- Rotate the JFrog access token and update the shell/CI secret value, then apply the workloads root.
- Rotate Grafana's admin password through Grafana and the Terraform input together to avoid drift.
- The secret is present in Kubernetes and Terraform state. Restrict Kubernetes RBAC, state bucket IAM, encryption keys, state lock access, backups, and CI artifacts accordingly.
- Never commit `terraform.tfvars`, state, plans, or secret-bearing logs. A saved Terraform plan may contain secret values; handle it as sensitive and delete it after use.

## Teardown

Delete workload resources first, then AWS infrastructure:

```sh
cd workloads
terraform destroy
cd ../infra
terraform destroy
```

EFS and the PV reclaim policy are `Retain` to prevent accidental model-cache deletion. Before infra destroy, remove the retained EFS filesystem and contents deliberately in AWS if you no longer need them. Review the destroy plan: NAT Gateway, EKS cluster, and GPU node termination are billable/destructive. Preserve or securely delete Terraform state based on your recovery and audit policy.
