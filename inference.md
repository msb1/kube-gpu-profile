# Private HTTPS inference endpoint

Terraform creates a dedicated internal inference ALB, two API-key gateway pods, an ACM certificate with automatic DNS validation, a private Route 53 endpoint name, and backend network policy. This ALB is separate from Grafana's internal ALB. All resources are defined in [workloads/inference.tf](workloads/inference.tf); gateway templates are in [workloads/gateway](workloads/gateway), and inputs are in [workloads/inference-variables.tf](workloads/inference-variables.tf).

## Request path

```text
Private application / VPN client
  → private DNS name, HTTPS :443
  → dedicated internal inference ALB (TLS termination and CIDR allowlist)
  → NGINX API-key gateway pod :8080
  → ready Triton pod :9000, chosen per request
  → Triton OpenAI frontend → vLLM → selected model on GPU
```

TLS terminates at the ALB. ALB-to-gateway and gateway-to-Triton traffic is HTTP inside the VPC; this implementation does not provide pod-to-pod TLS. The ALB uses IP targets for gateway pods and has no shared IngressGroup with Grafana. API keys are checked in the gateway, not by ALB or Triton.

The gateway uses a headless `triton-backends` Service to discover only ready Triton pod IPs. NGINX's dynamic DNS upstream resolves every five seconds and uses least-connections selection per request. This avoids pinning all requests to one Triton pod merely because an application or gateway reuses HTTP connections. Each gateway maintains its own balancing state. DNS and endpoint changes propagate asynchronously, so this is not an instantaneous global scheduler. Existing streams retain their original upstream connection and never migrate when replicas are added or removed. Failed inference requests are not automatically replayed on another replica.

## Prerequisites and inputs

Infrastructure must be applied first, including the VPC CNI configuration enabling Kubernetes network policy. Keep the two CPU system nodes available: gateway replicas use required anti-affinity across hosts. An existing authoritative **public Route 53 parent hosted zone** for a domain you own is required for ACM DNS validation. It must be publicly delegated correctly; a private-only zone or `.internal` name cannot validate a public ACM certificate. The certificate lives in the same AWS region as the ALB.

Configure the workload inputs:

```hcl
inference_hostname                       = "llm.inference.example.com"
inference_certificate_validation_zone_id = "Z0123456789EXAMPLE"
inference_ingress_cidrs                   = ["10.40.0.0/16", "10.80.0.0/16"]
inference_stream_timeout_seconds          = 900
```

Use the actual client/VPN source CIDRs seen by the ALB. Terraform rejects `0.0.0.0/0`; there is no public inference listener or HTTP listener. The HTTPS listener requires TLS 1.2 or newer. Terraform creates a private hosted zone for the exact endpoint hostname, associates it with `vpc_id`, and creates an alias A record to the inference ALB. The public parent zone receives only ACM's validation CNAME, not a public inference address.

The operator needs ACM request/describe/delete, Route 53 hosted-zone/record/VPC-association permissions and ELB describe access in addition to existing Terraform privileges. DNS validation records remain managed for certificate renewal. Other VPCs need deliberate private-zone associations or Route 53 Resolver forwarding; VPN/on-premises clients must resolve through a DNS path that can see the private hosted zone. The raw ALB hostname does not match the endpoint certificate; use the configured inference hostname.

`inference_gateway_image` defaults to the official `nginxinc/nginx-unprivileged` 1.28 Alpine image pinned by digest. NGINX 1.27.3 or newer is required for open-source dynamic upstream DNS resolution. The image runs without root, has a read-only root filesystem, drops all Linux capabilities and uses an emptyDir for temporary files. Review and pin a new digest for image/security upgrades; no custom gateway image build is required.

## API keys and deployment

Generate at least 32 random bytes per key and supply keys through your secret store or environment. Terraform accepts distinct 32–128-character keys containing letters, digits, `_` and `-`. A base64url-encoded random value is suitable. Supply the Terraform variable as a JSON array:

```sh
# Replace the example value with a randomly generated secret.
export TF_VAR_inference_api_keys='["REPLACE_WITH_A_RANDOM_URL_SAFE_KEY_OF_AT_LEAST_32_CHARACTERS"]'
cd workloads
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform output -raw inference_base_url
```

The key array is sensitive in Terraform output, but its rendered NGINX map is stored in Terraform state and the `inference-api-keys` Kubernetes Secret. Restrict state, plan-file, Secret and pod-exec permissions. Keys are never placed in a ConfigMap. Configuration/key changes trigger a gateway rolling update automatically. Two replicas, a one-available disruption budget and one-at-a-time rollout retain a gateway during maintenance.

The gateway accepts `Authorization: Bearer <key>` on `/v1/` routes, compares the key case-sensitively, and removes Authorization before forwarding to Triton. It returns HTTP 401 for absent or invalid credentials. Bearer scheme casing is accepted case-insensitively; key casing must match exactly. `/healthz` is an unauthenticated local gateway probe, and other non-API paths, including `/metrics`, return 404. There is no API-key query-string authentication. Access logs omit keys, request bodies and query strings.

## Client configuration

Run clients from an allowed private network with working private DNS. Set `INFERENCE_BASE_URL` to the `inference_base_url` output and `INFERENCE_API_KEY` to a configured key. The URL includes `/v1`:

```sh
export INFERENCE_BASE_URL='https://llm.inference.example.com/v1'
# Set INFERENCE_API_KEY from your secret store without printing it.
curl --fail-with-body "$INFERENCE_BASE_URL/models" \
  -H "Authorization: Bearer $INFERENCE_API_KEY"
curl --fail-with-body --no-buffer "$INFERENCE_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $INFERENCE_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25_7b_instruct","messages":[{"role":"user","content":"Explain PagedAttention briefly."}],"max_tokens":128,"stream":true}'
```

For an OpenAI-compatible SDK, supply `base_url=INFERENCE_BASE_URL`, `api_key=INFERENCE_API_KEY`, and `model` matching `selected_model`. Cluster-internal application clients should also use the authenticated HTTPS endpoint; an internal diagnostic can reach the gateway Service at `http://inference-gateway.llm-serving.svc.cluster.local:8080/v1` with the same key. That Service path does not provide TLS.

## Streaming, scaling and health

Response buffering, request buffering, compression, proxy caching and upstream retries are disabled for API routes. SSE data is forwarded as it arrives. The default `inference_stream_timeout_seconds=900` controls ALB idle timeout, proxy read/send inactivity timeouts, target deregistration delay and gateway graceful worker-shutdown budget. These are inactivity/drain budgets, not a promise that every 15-minute request succeeds. Active streams may exceed an inactivity timeout if data keeps flowing, but pod termination and the drain deadline can still cut them off.

Gateway and Triton pod termination grace is timeout + 30 seconds. Terraform allows up to 130 minutes for a two-gateway rollout; the Triton update timeout scales with the configured fleet limit and stream budget, with additional cold-start allowance, because the single spare GPU can serialize replacement. Both wait 15 seconds for endpoint removal; gateway then explicitly sends NGINX graceful quit. The Triton frontend's own shutdown behavior still needs live validation with your image/model. Karpenter's node drain deadline remains 15 minutes, so increasing the stream timeout above that does not extend the node deadline. Forced failures, preemptions, application crashes or streams exceeding a termination budget can interrupt responses. No stream is migrated or replayed.

ALB health checks use `/healthz` on the gateway. This verifies gateway availability, not model availability. Triton startup/readiness probes determine which pod IPs enter the headless Service. If no Triton pod is ready, authorized API requests return a gateway error (typically 502); keeping the gateway healthy does not mean the model is serving. The gateway itself does not wake a zero-replica deployment or buffer requests. KEDA continues scaling from scheduler metrics, retaining a minimum of one replica during normal operation.

## Backend access policy

`triton-gateway-only` allows port 9000 only from gateway-labelled pods in the serving namespace. Port 8002 is allowed only from Prometheus-labelled pods in `observability`. This applies to both the original Triton ClusterIP and headless Service because policy selects the backend pods. VPC CNI network-policy support is enabled in infra; apply infra first and verify the policy agent and enforcement before relying on the restriction. Restrict who may create pods or set trusted labels in these namespaces.

The original `triton-vllm` ClusterIP Service exposes port 8000 and forwards it to port 9000 on a selected Triton pod, where the OpenAI frontend listens. The gateway instead uses the headless `triton-backends` Service to discover ready pod IPs and connects directly to those pods on port 9000. Both paths reach the same backend port, so the policy specifies 9000; the ClusterIP Service's port 8000 does not bypass the policy.

The CNI uses its default standard enforcement mode, which can temporarily allow traffic while policy is attached to a new pod. This is not isolation from privileged node processes, host-network traffic, cluster administrators or authorized port-forward users. A strict-mode deployment requires explicit policies for every required system/app endpoint, including DNS, and a staged rollout; changing that cluster-wide mode without those policies can break existing features. Treat network policy as backend access control within the cluster trust boundary, rather than authentication enforced by Triton itself.

## Verification and troubleshooting

After apply, verify the actual endpoint and certificate from an allowed client network:

1. Check `kubectl -n llm-serving get ingress inference`, gateway pods and the ALB's healthy targets. Replace the namespace if configured differently.
2. Resolve `inference_hostname` through the VPC resolver and confirm the certificate hostname and trust chain. Do not disable TLS verification or test only the raw ALB hostname.
3. Request `/v1/models` with no key and a wrong key; expect 401. Use a valid key; expect the selected model. Check both key variants during rotation.
4. Send several streaming requests over reused client connections. Confirm prompt delivery is incremental and that newly ready replicas receive requests. Observe NGINX's `upstream=` access-log field and per-pod Triton metrics.
5. From an ordinary untrusted test pod, confirm direct port 9000 to Triton is denied; confirm Prometheus still scrapes port 8002. Verify the CNI policy agent is running. A port-forward is an administrator path and does not prove pod network isolation.
6. Drain one gateway during streaming and test Triton scale down under finite load. Confirm the grace budget is appropriate for your actual response lengths.

A pending ACM validation usually means the public parent zone is not authoritative or the validation CNAME has not propagated. An unresolved private name usually means private-zone association or VPN resolver forwarding is missing. ALB 503 generally means no healthy gateway targets; 401 means the gateway rejected credentials; gateway 502 with healthy gateways usually means no ready/reachable Triton upstream. Check headless Service EndpointSlices, DNS, backend readiness and network policy. The gateway's `/healthz` stays healthy when the model is unavailable by design.

The local gateway integration check in `tools/validation/test_inference_gateway.py` uses the actual Terraform templates and a native NGINX binary to exercise authentication, forwarding, streaming, no replay and endpoint refresh without AWS. It uses synthetic DNS/HTTP backends; on systems without a second loopback address it uses two dynamic upstream names/ports. It does not validate the container's security context, AWS TLS/DNS/ALB behavior or EKS policy enforcement. Run it with `python3 tools/validation/test_inference_gateway.py --nginx /path/to/nginx --terraform /path/to/terraform -v`. Perform the checks above in a staging deployment before production.

## Rotation, maintenance and teardown

Rotate keys in two phases: add a new key alongside the old key and apply; wait for the gateway rollout and test the new key; update clients; remove the old key and apply again. Old gateway workers retain their parsed configuration while draining, so revocation is not instantaneous across a rolling fleet. For immediate revocation, coordinate a traffic interruption and terminate old gateway workers, accepting that their streams will be cut off. Long-lived streams authenticated before revocation can continue until their drain budget expires.

Monitor gateway pod availability, 401/5xx access logs and ALB target health. This implementation provides shared bearer keys, not per-user identities, quotas, rate limiting or a centralized gateway log pipeline. Review certificate renewal, image digests, CIDRs and key rotation periodically.

For teardown, stop clients and drain inference before deleting workloads. Kubernetes Ingress deletion lets AWS Load Balancer Controller clean up the inference ALB; keep that controller running until ALBs and target groups disappear. Terraform removes its private hosted zone, alias, ACM certificate and validation record. The existing Karpenter NodeClaim/EC2 drain procedure still applies before destroying infrastructure. Two ALBs, the private hosted zone and gateway CPU usage add cost; AWS-managed public ACM certificates used on ALB normally have no separate certificate charge.

Official references: [ALB annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/), [NGINX upstream DNS resolution](https://nginx.org/en/docs/http/ngx_http_upstream_module.html), [NGINX proxy buffering and retries](https://nginx.org/en/docs/http/ngx_http_proxy_module.html), [unprivileged NGINX image](https://github.com/nginx/docker-nginx-unprivileged), [VPC CNI network policies](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html).

## Model artifacts and storage

The model files and the inference server image are separate artifacts. The server image contains Triton, its OpenAI-compatible frontend and the vLLM backend; model weights are not baked into it. The path for the model files is:

```text
Hugging Face or another approved source
    -> operator prepares and uploads a tar.gz archive
JFrog Artifactory: one archive per model alias
    -> pod init container downloads and extracts the archives
EFS: shared, persistent cache of extracted model files
    -> vLLM reads the selected model during startup
Triton/vLLM: a running model instance on each replica's GPU
```

The **weights** are the trained numerical parameters, typically in large files such as `*.safetensors`. The model snapshot also includes architecture and other settings, usually in `config.json`, tokenizer files for converting text to and from tokens, and potentially other files required by that model. A **loaded model** is the running vLLM engine initialized from those files, including its GPU-resident weights and runtime allocations. The runtime KV cache is distinct from the persistent model-file cache on EFS.

Prepare the artifacts before applying the workloads configuration:

1. Obtain a complete snapshot for each model from Hugging Face or an approved model source, subject to its access permissions and license. Include every weight shard, model configuration, tokenizer file and any other files the model requires. Validate that the model architecture and its weight format are supported by the vLLM version in the pinned Triton image.
2. Create a self-contained `tar.gz` for each snapshot, with the snapshot files directly at the archive root, not inside an additional enclosing directory. Materialize any symlinks into a local download cache before packaging. [operation.md](operation.md#how-the-llm-is-loaded) contains preparation guidance.
3. Upload the archives to a JFrog Artifactory generic repository and supply their direct HTTPS download URLs in `model_archive_urls` in `workloads/terraform.tfvars`. The configured aliases are `qwen25_7b_instruct`, `qwen35_8b`, and `llama31_8b_instruct`; Terraform does not infer artifact names or upload the snapshots. Supply the download token through `TF_VAR_artifactory_token` and choose the serving alias with `selected_model`. See [the example variables](workloads/terraform.tfvars.example).

This deployment does not download model files directly from Hugging Face at runtime. The first pod start can take a long time because it downloads and extracts all three archives, even though only one model is loaded for serving.

## Loading the selected model

Terraform creates the EFS-backed persistent volume and claim, the Triton deployment, an Artifactory token Secret, and ConfigMaps containing Triton model configuration. The implementation is in [workloads/models.tf](workloads/models.tf). The sequence at pod startup is:

1. The `artifactory-model-cache` init container mounts EFS at `/models` and acquires a shared directory lock so concurrent replicas do not populate the cache simultaneously.
2. For each alias, it checks `/models/cache/<alias>/.download-complete`. If the marker is absent, it downloads the corresponding archive using the bearer token, temporarily stores it on EFS, extracts it into `/models/cache/<alias>`, deletes the compressed archive, and creates the marker. If the marker exists, it reuses the cached files. The main container starts only after the init container succeeds for all three aliases.
3. Terraform-generated `config.pbtxt` entries select the Triton `vllm` backend. Each corresponding `model.json` points to `/models/cache/<alias>` and supplies settings including GPU memory utilization, maximum model length and tensor parallel size. The frontend uses the selected model's tokenizer from the same cache.
4. The frontend starts Triton with explicit model control and `--load-model=<selected_model>`. The vLLM backend reads the selected snapshot from EFS and initializes the model on the GPU. Each serving replica requests a GPU and loads its own model copy; EFS shares the files, not GPU memory. Triton readiness determines when the replica can receive inference traffic.

EFS therefore holds the extracted snapshots for all three aliases, including weight shards, tokenizer and configuration files, other archive contents, and completion markers. The compressed archive is removed after successful extraction; Artifactory remains the archive source. EFS persists independently of pod and node restarts. In this configuration the model files are always present in the EFS cache before the main container loads them; a cache hit avoids a new Artifactory download, but each new replica still initializes its own GPU copy.

The completion marker only indicates that the init container previously completed extraction; it does not verify the files against the current archive or a checksum. Replacing an artifact at the same URL does not automatically refresh the cache. Coordinate cache invalidation and restart as described in [operation.md](operation.md#switch-the-active-model), and use immutable versioned artifacts and integrity verification for production. If an init container is interrupted, inspect incomplete files or a stale lock before retrying. Check progress with `kubectl -n llm-serving logs deploy/triton-vllm -c artifactory-model-cache`, replacing the namespace if configured differently. A successful download does not guarantee the model fits GPU memory or is compatible with the image; verify that the selected model becomes ready.
