# Operations guide

Before following the deployment commands below, complete the [autoscaling image, AMI, input wiring and migration procedure](autoscaling.md#deployment-and-migration-checklist). The stock Triton image is no longer a valid `triton_image` input. Also complete [inference endpoint setup](inference.md): Terraform creates the separate internal HTTPS ALB, API-key gateway, ACM validation and private DNS.

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
- An owned DNS hostname and existing authoritative public Route 53 parent zone for automatic ACM validation. Terraform creates a private zone/alias for the inference endpoint; VPN clients need private DNS resolution.
- One or more randomly generated inference API keys supplied as `TF_VAR_inference_api_keys`, a JSON array; see [inference.md](inference.md).

## How the LLM is loaded

You need both a container image for the inference server and separate model files. The model weights are not baked into the server image, and this setup does not download models directly from Hugging Face at runtime.

| Item | Purpose | Configuration or implementation |
| --- | --- | --- |
| Custom Docker image | Contains Triton, vLLM, the OpenAI frontend, and the autoscaling metrics extension | Build [images/triton-metrics/Dockerfile](images/triton-metrics/Dockerfile); set `triton_image` to the published image digest |
| Model archives | Contain Hugging Face model weights, tokenizer, and configuration files | Set all three `model_archive_urls` in `workloads/terraform.tfvars`; see [the example](workloads/terraform.tfvars.example) |
| Active model | Chooses which cached model each serving replica loads into its GPU | Set `selected_model` in `workloads/terraform.tfvars` |

The loading sequence is implemented in [workloads/models.tf](workloads/models.tf):

1. The `artifactory-model-cache` init container downloads all three archives from JFrog Artifactory using the bearer token supplied through `TF_VAR_artifactory_token`. It extracts each archive into `/models/cache/<model-alias>` on shared EFS storage. A directory lock serializes concurrent downloads, and a `.download-complete` marker allows subsequent starts to reuse the cached files.
2. Terraform generates each model's `config.pbtxt` and `model.json` through the `triton_models` ConfigMaps. The configuration selects the vLLM backend and points its `model` setting to the local EFS path, such as `/models/cache/qwen25_7b_instruct`.
3. The main container starts the OpenAI frontend with `--model-control-mode=explicit` and `--load-model=<selected_model>`. Triton initializes the vLLM backend, which reads the selected weights and tokenizer from EFS and loads the model into GPU memory. Each replica loads its own model copy onto its own GPU; the other two models remain cached on EFS.

To prepare an archive, obtain the complete model snapshot from Hugging Face or your approved model source, including all weight shards, tokenizer files, and model configuration files. Package the snapshot contents at the archive root, rather than inside an extra enclosing directory. For example, from the repository root:

```sh
tar -czf qwen2.5-7b-instruct.tar.gz -C /path/to/complete-model-snapshot .
```

If the snapshot uses symbolic links into a local download cache, first materialize those files into a self-contained directory. Upload the archive to Artifactory and put its direct HTTPS download URL in the corresponding `model_archive_urls` entry. Repeat for all three configured aliases. Model access permissions, licenses, and compatibility with the bundled vLLM version must be satisfied for the artifacts you use.

Build and publish the custom server image separately, following [the image build instructions](autoscaling.md#custom-image-and-metrics-contract). The Dockerfile adds the metrics extension to the NVIDIA Triton image; it does not download or package the LLM weights. For model changes after deployment, see [Switch the active model](#switch-the-active-model).

## Configure

Copy both example files and edit them. These files are ignored by Git.

```sh
cp infra/terraform.tfvars.example infra/terraform.tfvars
cp workloads/terraform.tfvars.example workloads/terraform.tfvars
```

In `infra/terraform.tfvars`, set a secure API CIDR, the IAM role/user ARN, region, and instance choice. `g7.8xlarge` is the default; if unavailable, choose `g5.4xlarge` or `g6.8xlarge`. Check the region's GPU quotas and availability before spending time on apply.

In `workloads/terraform.tfvars`, set `inference_hostname`, `inference_certificate_validation_zone_id` (public parent zone), `inference_ingress_cidrs`, and the Karpenter outputs, `private_subnet_ids`, `node_security_group_id`, tested `gpu_ami_id`, custom digest-pinned `triton_image`, and `cluster_name`, `aws_region`, `vpc_id`, `efs_file_system_id`, `aws_load_balancer_controller_role_arn`, `grafana_ingress_cidrs`, and the three direct archive URLs. The role ARN and VPC ID are outputs from the infra root. Set the CIDR list to the trusted VPN/private client networks that need Grafana access. Do not put JFrog or Grafana passwords in this file. Export Terraform input variables in your shell or CI secret store instead:

```sh
export TF_VAR_artifactory_token='your-jfrog-token'
export TF_VAR_grafana_admin_password='use-a-unique-long-password'
# Load actual randomly generated keys from your secret store as a JSON array:
export TF_VAR_inference_api_keys='["REPLACE_WITH_A_RANDOM_URL_SAFE_KEY_OF_AT_LEAST_32_CHARACTERS"]'
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
terraform output -raw karpenter_role_arn
terraform output -raw karpenter_node_role_name
terraform output -raw karpenter_queue_name
terraform output -json private_subnet_ids
terraform output -raw node_security_group_id
```

Configure `workloads/terraform.tfvars` with those values, including `grafana_ingress_cidrs` set to the trusted VPN/private network CIDRs that should reach the internal Grafana load balancer. Then configure kubectl. From the `infra/` directory:

```sh
aws eks update-kubeconfig --region "$(terraform output -raw aws_region)" --name "$(terraform output -raw cluster_name)"
kubectl get nodes -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu
```

Wait until the two CPU system nodes are `Ready`. Karpenter creates the first GPU node during workloads apply; the NVIDIA plugin must then advertise its GPU. The workload provider root cannot be applied from a machine/network that cannot reach the EKS public endpoint. Restrict `admin_cidr_blocks` to the current trusted egress CIDR; use VPN or a controlled runner.

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

Verify GPU allocation and the authenticated inference endpoint from an allowed VPC/VPN client. Terraform creates two independent internal ALBs: inference uses HTTPS and bearer keys, while Grafana retains its existing listener and CIDR controls.

```sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu
kubectl -n llm-serving get ingress inference
kubectl -n llm-serving get pods -l app=inference-gateway
export INFERENCE_BASE_URL="$(terraform output -raw inference_base_url)"
# Supply INFERENCE_API_KEY from the secret store, matching a configured key.
curl --fail-with-body "$INFERENCE_BASE_URL/models" \
  -H "Authorization: Bearer $INFERENCE_API_KEY"
curl --fail-with-body --no-buffer "$INFERENCE_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $INFERENCE_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25_7b_instruct","messages":[{"role":"user","content":"Explain PagedAttention in one sentence."}],"temperature":0.2,"max_tokens":128,"stream":true}'
```

Requests to `/v1/models` without a key or with an invalid key must return 401. Use the configured inference DNS hostname so TLS certificate validation succeeds; the raw ALB hostname does not match the certificate. [inference.md](inference.md) includes DNS, certificate, streaming, key rotation and network-policy verification.

For an administrator-only backend readiness/metrics check, use a temporary port-forward. This bypasses the gateway and is not a test of authentication or pod network isolation:

```sh
kubectl -n llm-serving port-forward svc/triton-vllm 8000:8000 8002:8002
# In another terminal:
curl -fsS http://127.0.0.1:8000/health/ready
curl -fsS http://127.0.0.1:8002/metrics | grep -E 'llm_|nv_gpu|vllm:' | head
```

The OpenAI-compatible frontend is launched from the pinned Triton `26.04-vllm-python-py3` image and uses the selected model's tokenizer from `/models/cache/<selected_model>`. Confirm that the image contains the frontend and that the bundled vLLM supports each artifact architecture before serving traffic. Also confirm the GPU node's NVIDIA driver meets the image's CUDA driver minimum. The EKS NVIDIA AMI is updated independently of the Triton image.

The `model` field must match the active `selected_model`. The Grafana ALB is private: connect your workstation to the VPC through the organization's VPN or another approved private network path. The ingress's CIDR allowlist must include that trusted client network. After workload apply, get the ALB hostname with:

```sh
terraform output -raw grafana_internal_alb_hostname
kubectl -n observability get ingress grafana
```

The hostname resolves and connects only from the VPC or a connected network. Open `http://<hostname>/` and sign in as `admin` using the password supplied through `TF_VAR_grafana_admin_password`. The ALB is internal and HTTP-only in this starter configuration; use a private ACM certificate and HTTPS listener for production access across networks that are not fully trusted.

Application clients, including cluster-internal clients, should use the `inference_base_url` Terraform output with a configured bearer API key and `model` matching `selected_model`. The gateway validates the key and discovers ready Triton pods via a headless Service, balancing each new request while leaving active streams on their original pod. Direct API access to Triton is restricted by network policy; Prometheus retains access to metrics. Apply infra first to enable VPC CNI network-policy support and verify enforcement. See [inference.md](inference.md) for the standard-mode startup window and administrative access boundaries.

## Switch the active model

Set `selected_model` in `workloads/terraform.tfvars` to one of:

```hcl
selected_model = "qwen25_7b_instruct"
# selected_model = "qwen35_8b"
# selected_model = "llama31_8b_instruct"
```

Then run `terraform plan` and `terraform apply` in `workloads/`. The Triton OpenAI frontend restarts and loads the chosen model. Rolling updates preserve available replicas using one surge GPU; each new replica loads the chosen model. Existing streams and forced evictions still require careful handling. All archives remain cached on EFS. If replacing an archive at a URL, remove `/models/cache/<alias>/.download-complete` (and stale contents) from EFS before restarting, or use a new immutable URL.

## Scale GPU capacity

KEDA manages Triton replicas from `min_replicas` (default 1) to `max_replicas` (default 10), using scheduler KV-cache pressure and waiting requests. Karpenter provisions one GPU per pending Triton replica and consolidates empty nodes after ten minutes. See [autoscaling.md](autoscaling.md) for image builds, infra outputs, AMI selection, migration, full validation, tuning, rollback and shutdown.

Change bounds/thresholds in `workloads/terraform.tfvars` and apply workloads. Do not change `Deployment.spec.replicas` through Terraform: the HPA owns it. The legacy `gpu_desired_size`, `gpu_min_size`, `gpu_max_size` variables affect only the managed GPU group; keep desired/minimum zero after migration. Increasing those values adds manual capacity outside the Karpenter limit.

A minimum of one serving replica is required because pod-local metrics cannot wake a stopped service. To suspend GPU spending deliberately, stop clients, pause the ScaledObject, scale Triton to zero and let Karpenter delete empty nodes; restoring replicas is a manual action. EKS, CPU system nodes, NAT, EFS, logs and observability continue to incur charges.

## Secrets and state handling

- Rotate inference API keys with the two-phase overlap procedure in [inference.md](inference.md#rotation-maintenance-and-teardown); applying key changes rolls the gateway automatically.
- Rotate the JFrog access token and update the shell/CI secret value, then apply the workloads root.
- Rotate Grafana's admin password through Grafana and the Terraform input together to avoid drift.
- The secret is present in Kubernetes and Terraform state. Restrict Kubernetes RBAC, state bucket IAM, encryption keys, state lock access, backups, and CI artifacts accordingly.
- Never commit `terraform.tfvars`, state, plans, or secret-bearing logs. A saved Terraform plan may contain secret values; handle it as sensitive and delete it after use.

## Teardown

First stop inference ALB clients and drain gateway streams. Keep AWS Load Balancer Controller running until both ingress ALBs have been deleted. Follow the drain procedure in [autoscaling.md](autoscaling.md#failure-modes-rollback-and-teardown): pause scaling, scale serving to zero, delete the GPU NodePool while Karpenter is running, and wait for NodeClaims/EC2 instances to disappear. Then delete workload resources and AWS infrastructure:

```sh
cd workloads
terraform destroy
cd ../infra
terraform destroy
```

EFS and the PV reclaim policy are `Retain` to prevent accidental model-cache deletion. Before infra destroy, remove the retained EFS filesystem and contents deliberately in AWS if you no longer need them. Review the destroy plan: NAT Gateway, EKS cluster, and GPU node termination are billable/destructive. Preserve or securely delete Terraform state based on your recovery and audit policy.
