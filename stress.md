# Stress testing the OpenAI-compatible Triton/vLLM service

This guide exercises the OpenAI `/v1` API exposed by the workload Terraform. The NVIDIA Triton OpenAI frontend starts an in-process Triton server with the vLLM backend; requests reach the active model through `/v1/chat/completions` or `/v1/completions`. Only one selected model is loaded at a time on the single-GPU node.

## Included upstream benchmark sources

The repository contains upstream sources and their licenses under `tools/stress/upstream/`:

- `vllm/benchmarks/serve.py`: current vLLM online serving benchmark, which supports OpenAI-compatible chat and completions endpoints. The former `benchmarks/benchmark_serving.py` path has moved.
- `triton-perf-analyzer/genai-perf/`: NVIDIA GenAI-Perf source and docs. Its upstream README marks GenAI-Perf as phased out and recommends AIPerf for new work; GenAI-Perf is retained here as a Triton-focused benchmark option.
- `UPSTREAM_COMMIT` records the source revision in each directory. Keep the matching `LICENSE` files if redistributing these sources.

References: [vLLM online benchmark](https://github.com/vllm-project/vllm/blob/main/vllm/benchmarks/serve.py), [Triton OpenAI-compatible frontend](https://github.com/triton-inference-server/server/tree/main/python/openai), [Triton Performance Analyzer / GenAI-Perf](https://github.com/triton-inference-server/perf_analyzer/tree/main/genai-perf).

## Connect to the private service

The Service is `ClusterIP` only. From a workstation or controlled runner with EKS access, forward its OpenAI and metrics ports:

```sh
kubectl -n llm-serving port-forward svc/triton-vllm 8000:8000 8002:8002
```

In another terminal, set the selected Triton model alias and a local tokenizer path or Hugging Face tokenizer ID. GenAI-Perf needs the tokenizer to generate prompts of a target token length.

```sh
export MODEL=qwen25_7b_instruct
# Alternatives: qwen35_8b or llama31_8b_instruct
export TOKENIZER=/path/to/the/matching/tokenizer

curl -fsS http://127.0.0.1:8000/health/ready
curl -fsS http://127.0.0.1:8000/v1/models
curl -fsS http://127.0.0.1:8002/metrics | grep -E 'vllm:|nv_gpu' | head
```

The model alias must match the deployment's `selected_model`. The tokenizer should match the active artifact; a Triton alias is not necessarily a Hugging Face tokenizer identifier. For gated tokenizers, configure Hugging Face credentials on the benchmark client. Do not send confidential prompts during load tests.

Smoke-test a chat completion before load:

```sh
curl -fsS http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"'"$MODEL"'","messages":[{"role":"user","content":"Explain continuous batching in one short paragraph."}],"temperature":0,"max_tokens":96,"stream":false}'
```

## vLLM online serving benchmark

Use a client environment with a compatible vLLM installation; `vllm bench serve` ships this benchmark. It calls the OpenAI-compatible API and can generate random prompts without a ShareGPT dataset.

```sh
vllm bench serve \
  --backend openai-chat \
  --base-url http://127.0.0.1:8000 \
  --endpoint /v1/chat/completions \
  --model "$MODEL" \
  --tokenizer "$TOKENIZER" \
  --dataset-name random \
  --input-len 256 \
  --output-len 128 \
  --request-rate 1 \
  --num-prompts 100
```

The original example's `--backend openai` and ShareGPT arguments target an OpenAI-style completions endpoint and an older script location. For this chat API, `openai-chat` and `--endpoint /v1/chat/completions` are appropriate; the random dataset avoids a separate ShareGPT download. To run the checked-in source directly, use an environment where the matching `vllm` Python package is installed:

```sh
python tools/stress/upstream/vllm/benchmarks/serve.py \
  --backend openai-chat \
  --base-url http://127.0.0.1:8000 \
  --endpoint /v1/chat/completions \
  --model "$MODEL" \
  --tokenizer "$TOKENIZER" \
  --dataset-name random \
  --input-len 256 \
  --output-len 128 \
  --request-rate 1 \
  --num-prompts 100
```

Increase request rate in separate runs, such as 0.5, 1, 2, then 4 requests per second. Keep request counts finite and note whether the tool is reaching the target rate; use its `--help` output for additional current options and latency metrics.

## Locust step-load capacity test

`tools/locust-capacity/locustfile.py` simulates end-user chat sessions against this deployment's OpenAI-compatible Triton `/v1/chat/completions` endpoint. It parses the Server-Sent Events (SSE) stream and records **TTFT to the first non-empty text delta** separately from the full request duration. The script also reports mean time between content-bearing SSE chunks as a secondary streaming signal.

SSE chunks are not guaranteed to correspond one-to-one with generated tokens. Therefore this Locust value is explicitly named *inter-content-chunk interval*, not token-level ITL. Use Triton's `vllm:time_per_output_token_seconds` histogram in Grafana for the backend's supported ITL/TPOT measure. This Triton backend does not currently expose KV-cache usage or preemption counters to Prometheus; GPU framebuffer use is available through DCGM but is not a substitute for KV-cache utilization.

### Connect the Locust client

The inference Service is private. Run Locust from an approved client on the VPC/VPN network, or use the same temporary API port-forward as the other tests. For a workstation with EKS access, in a separate terminal:

```sh
kubectl -n llm-serving port-forward svc/triton-vllm 8000:8000
```

Use the Python environment from `~/Code/rag-bench` as requested. Activate that project's virtual environment and install Locust there if needed:

```sh
cd ~/Code/rag-bench
source .venv/bin/activate  # adjust to the virtual environment used by rag-bench
python -m pip install locust
```

Run the test with the script in this repository. The built-in load shape starts at 5 users, adds 5 users over 5 seconds every 30 seconds, and holds the maximum for 2 minutes. At 100 users the default run lasts about 12 minutes. No ShareGPT dataset is downloaded or required; each virtual user sends the configured prompt.

```sh
cd ~/Code/rag-bench
mkdir -p capacity-results
MODEL=qwen25_7b_instruct \
MAX_TOKENS=256 \
STEP_USERS=5 \
STEP_SECONDS=30 \
STEP_SPAWN_SECONDS=5 \
MAX_USERS=100 \
HOLD_SECONDS=120 \
WAIT_TIME_MIN=2 \
WAIT_TIME_MAX=5 \
locust -f ~/Code/kube-gpu-profile/tools/locust-capacity/locustfile.py \
  --headless \
  --host http://127.0.0.1:8000 \
  --csv capacity-results/locust \
  --csv-full-history \
  --html capacity-results/locust-report.html
```

`MODEL` must equal the active Terraform `selected_model`: `qwen25_7b_instruct`, `qwen35_8b`, or `llama31_8b_instruct`. The endpoint may require a larger `model_max_len` or lower `MAX_TOKENS` if your configured context window is smaller. Set `LOCUST_PROMPT` to a representative, non-confidential prompt. The default user wait is 2–5 seconds; adjust `WAIT_TIME_MIN`/`WAIT_TIME_MAX` to model your application's request cadence. If Locust runs directly on the VPC, use `--host http://<private-client-reachable-address>:8000` instead of localhost and omit the port-forward.

If API-key authentication is later enforced on `/v1`, export `API_KEY` from your secret store before starting Locust; the script sends it as `Authorization: Bearer …`. Do not put the key in the command line, CSV, or a committed file.

For a shorter pilot, lower `MAX_USERS`; for finer resolution use `STEP_USERS=1` and increase `STEP_SECONDS`. Do not change several workload factors at once. Run a warm-up, then repeat the same prompt, output cap, step schedule, model, and instance type for comparisons.

### Read the capacity result

- In Locust, inspect `/v1/chat/completions (stream)` for request count, request rate, failures, and end-to-end response time. Inspect the `LLM metric` rows **TTFT (first text delta)** and **Mean inter-content-chunk interval (not token ITL)** for their own distributions. These custom metric events also appear as rows in Locust statistics; use the named endpoint row for actual API request counts and request rate, not an aggregate that mixes custom measurements.
- The step shape ramps **virtual users**; it does not guarantee the same number of simultaneous in-flight generations. Each user waits 2–5 seconds after a response. Record actual API RPS and request latency at each plateau. A rough estimate of mean in-flight requests is `RPS × mean request duration in seconds` (Little's Law); it will usually be below the active virtual-user count.
- Treat TTFT p95 above 1,500 ms as an example warning threshold only if it matches your service objective. Establish a TPOT/ITL limit from the product's latency goal; lower ITL is faster, and rising ITL is degradation. The earlier suggestion that ITL *dropping below* 30 ms signals degradation has the direction reversed; 30 ms may be a target, not a universal cutoff.
- In the provisioned Grafana dashboard, correlate each plateau with `DCGM_FI_DEV_GPU_UTIL`, framebuffer memory used/free, the four DCGM profiling counters, vLLM token throughput, TTFT and TPOT. Use `dcgmi dmon` through the SSM path only if the optional host DCGM package/engine is enabled in both Terraform roots as described in [operation.md](operation.md).
- The maximum acceptable capacity tier is the highest sustained plateau that meets the chosen TTFT/TPOT and error-rate objectives without GPU memory exhaustion, pod restarts, or throughput collapse. Confirm it in at least two repeat runs and select an operational limit below the first failing tier to leave headroom.

Do not label a plateau as “KV-cache exhausted” from rising latency or framebuffer usage alone: the current Triton vLLM integration does not forward KV-cache usage or preemption metrics. Likewise, GPU utilization below 100% does not rule out queueing, memory pressure, or a client-side bottleneck. Record the evidence and call it capacity degradation unless direct KV-cache telemetry becomes available.

## NVIDIA GenAI-Perf

Install the checked-in source in a virtual environment (Python 3.10 or newer):

```sh
python3 -m venv .venv-stress
source .venv-stress/bin/activate
python -m pip install --upgrade pip
python -m pip install -e tools/stress/upstream/triton-perf-analyzer/genai-perf
genai-perf --help
```

Start with a streaming profile at concurrency 1:

```sh
mkdir -p stress-results
genai-perf profile \
  --model "$MODEL" \
  --tokenizer "$TOKENIZER" \
  --service-kind openai \
  --endpoint-type chat \
  --url http://127.0.0.1:8000 \
  --streaming \
  --synthetic-input-tokens-mean 256 \
  --synthetic-input-tokens-stddev 32 \
  --output-tokens-mean 128 \
  --output-tokens-stddev 16 \
  --request-count 100 \
  --warmup-request-count 10 \
  --concurrency 1 \
  --artifact-dir stress-results
```

GenAI-Perf reports TTFT, inter-token latency, request latency and token/request throughput, and saves JSON/CSV artifacts. Increase concurrency gradually in independent runs:

```sh
for C in 1 2 4 8 12 16; do
  genai-perf profile \
    --model "$MODEL" \
    --tokenizer "$TOKENIZER" \
    --service-kind openai \
    --endpoint-type chat \
    --url http://127.0.0.1:8000 \
    --streaming \
    --synthetic-input-tokens-mean 256 \
    --synthetic-input-tokens-stddev 32 \
    --output-tokens-mean 128 \
    --output-tokens-stddev 16 \
    --request-count 200 \
    --warmup-request-count 10 \
    --concurrency "$C" \
    --artifact-dir "stress-results/${C}-concurrency"
done
```

The target input and output lengths must fit `model_max_len` from `workloads/terraform.tfvars`. Stop if GPU memory approaches capacity, errors or pod restarts appear, or tail latency exceeds your service objective. Check `genai-perf profile --help` if upstream CLI options differ from the checked-in revision.

## Macro GPU profiling and LLM cache-pressure signals

Terraform configures DCGM Exporter with a custom collector list for the DCGM profiling fields below, grants the exporter the `SYS_ADMIN` capability required for profiling counters, and installs the Grafana dashboard **LLM GPU Macro Profiling**. Grafana's Prometheus datasource reads the same Prometheus series collected by the `dcgm-exporter` and `triton-vllm` scrape jobs.

| What to inspect | Prometheus metric exposed by DCGM Exporter | Canonical DCGM field / ID | Interpretation |
| --- | --- | --- | --- |
| Tensor pipe activity | `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | `DCGM_FI_PROF_TENSOR_UTIL_RATIO` / 1004 | Tensor-pipe activity averaged over the sample interval; higher indicates more tensor-pipe use. |
| SM active warp ratio | `DCGM_FI_PROF_SM_ACTIVE` | `DCGM_FI_PROF_SM_UTIL_RATIO` / 1002 | Fraction of cycles with at least one active warp on an SM. It is not a direct measure of useful compute or “SM efficiency.” |
| DRAM interface activity | `DCGM_FI_PROF_DRAM_ACTIVE` | `DCGM_FI_PROF_DRAM_UTIL_RATIO` / 1005 | Fraction of cycles the device-memory interface is active; interpret with tensor activity and throughput. |
| FP16 pipe activity | `DCGM_FI_PROF_PIPE_FP16_ACTIVE` | `DCGM_FI_PROF_FP16_UTIL_RATIO` / 1008 | FP16-pipe activity. It does not identify model quantization or prove that a particular precision is in use. |

The names in the first column of the original field table are not the current Prometheus names. For example, DCGM Exporter exposes `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`, not `DCGM_FI_PROF_TENSOR_OP_UTIL`. NVIDIA documents these exporter aliases and their canonical field IDs in the [DCGM Exporter metric reference](https://docs.nvidia.com/datacenter/dcgm/latest/reference/dcgm-exporter-metrics.html). Terraform explicitly selects the four fields above because some are optional in the exporter's default counter list. The dashboard also includes ordinary GPU utilization/memory panels and the vLLM token-throughput/latency metrics supported by Triton's backend.

Use Grafana **Explore** or the provisioned dashboard to query:

```promql
DCGM_FI_PROF_PIPE_TENSOR_ACTIVE
DCGM_FI_PROF_SM_ACTIVE
DCGM_FI_PROF_DRAM_ACTIVE
DCGM_FI_PROF_PIPE_FP16_ACTIVE
DCGM_FI_DEV_GPU_UTIL
DCGM_FI_DEV_FB_USED
rate(vllm:prompt_tokens_total[5m])
rate(vllm:generation_tokens_total[5m])
rate(vllm:time_to_first_token_seconds_sum[5m]) / rate(vllm:time_to_first_token_seconds_count[5m])
rate(vllm:time_per_output_token_seconds_sum[5m]) / rate(vllm:time_per_output_token_seconds_count[5m])
```

DCGM profiling metrics are interval averages from hardware counters, not per-kernel traces. Field availability and simultaneous collection depend on GPU architecture, driver/DCGM compatibility, and which profiling tools are using the counters. This setup targets G5/A10G, G6/L4, and G7/RTX PRO GPUs, but a field can be absent or report no data on a particular device/driver combination. Check that the exporter target is `UP` and that the metric itself is present before interpreting a blank panel. Profiling field groups can compete for counter resources; in an environment with the DCGM CLI installed, inspect supported groups with `dcgmi profile --list --entity-id gpu:0`. A single-GPU node has no multi-GPU NVLink path to profile.

You do not need a node shell to see these counters: the configured DCGM Exporter scrapes them into Prometheus, and Grafana displays them during the benchmark. The infra Terraform configures AWS Systems Manager (SSM) access for the GPU worker role without opening inbound SSH or distributing SSH keys. To optionally install the host `dcgmi` CLI and DCGM engine, set `install_dcgm_cli = true` in infra and `use_host_dcgm_engine = true` in workloads before applying; this also configures DCGM Exporter to use that host engine. Follow [operation.md](operation.md) for setup and SSM shell access. Once the SSM association succeeds, `dcgmi dmon` provides a live terminal cross-check; Grafana still reads exporter metrics through Prometheus. Avoid running another profiling client if it conflicts for the same hardware counters.

### Stress prefill, decode, and KV cache

**KV-cache limitation:** although standalone vLLM currently documents `vllm:kv_cache_usage_perc` and `vllm:num_preemptions`, NVIDIA's Triton vLLM backend only forwards a supported subset of vLLM metrics to Triton's metrics endpoint. That subset includes prompt/generation token counts, TTFT, time-per-output-token, end-to-end latency, and request parameter histograms; it does not currently list KV-cache usage or preemption metrics. Those two metrics will therefore not appear in this deployment's Prometheus/Grafana unless the backend adds support or the serving architecture is changed. Standalone vLLM's metric names and definitions are in its [metrics reference](https://docs.vllm.ai/en/latest/usage/metrics/); Triton's forwarded metrics are listed in the [Triton vLLM backend docs](https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/vllm_backend/README.html).

With a serving path that does expose KV-cache telemetry, 1.0 in `vllm:kv_cache_usage_perc` means 100% KV-cache use. Correlate it with `vllm:num_preemptions`, waiting/running request gauges, TTFT, and inter-token latency. Cache pressure can cause scheduler delays or preemption/recomputation; it does not by itself mean vLLM is swapping requests to CPU. CPU KV offload is a separate configured feature. The metric name `vllm:gpu_cache_usage_factor` in the sample guidance is not the documented standalone vLLM metric name, and neither cache usage nor preemptions are currently forwarded by this Triton backend, so they cannot be watched in this stack's Grafana dashboard. For this deployment, use high concurrency together with rising TTFT/ITL, falling throughput, or errors as indirect signs of saturation; these do not prove KV-cache exhaustion on their own.

Run matched prefill tests with short and long prompts. Keep combined prompt and output lengths below `model_max_len` (default 8192); chat-template tokens add some overhead.

```sh
# Short prefill: about 100 input tokens, 256 output tokens
genai-perf profile \
  --model "$MODEL" --tokenizer "$TOKENIZER" \
  --service-kind openai --endpoint-type chat \
  --url http://127.0.0.1:8000 --streaming \
  --synthetic-input-tokens-mean 100 --synthetic-input-tokens-stddev 0 \
  --output-tokens-mean 256 --output-tokens-stddev 0 \
  --request-count 100 --warmup-request-count 10 --concurrency 2 \
  --artifact-dir stress-results/prefill-100

# Long prefill: about 4096 input tokens, 512 output tokens
genai-perf profile \
  --model "$MODEL" --tokenizer "$TOKENIZER" \
  --service-kind openai --endpoint-type chat \
  --url http://127.0.0.1:8000 --streaming \
  --synthetic-input-tokens-mean 4096 --synthetic-input-tokens-stddev 0 \
  --output-tokens-mean 512 --output-tokens-stddev 0 \
  --request-count 100 --warmup-request-count 10 --concurrency 2 \
  --artifact-dir stress-results/prefill-4096

# Decode-heavy run: short prompt, long generation
genai-perf profile \
  --model "$MODEL" --tokenizer "$TOKENIZER" \
  --service-kind openai --endpoint-type chat \
  --url http://127.0.0.1:8000 --streaming \
  --synthetic-input-tokens-mean 100 --synthetic-input-tokens-stddev 0 \
  --output-tokens-mean 2048 --output-tokens-stddev 0 \
  --request-count 100 --warmup-request-count 10 --concurrency 2 \
  --artifact-dir stress-results/decode-2048
```

The long-prompt run stresses prefill and KV allocation; the decode-heavy run keeps sequences active longer. Watch tensor/DRAM activity, GPU memory, TTFT, token throughput, and inter-token latency together. High DRAM activity with modest tensor activity can indicate a memory-bound phase, but these aggregate counters alone do not prove a bottleneck. The 4096-token prompt is a workload choice, not a guarantee it fits: keep prompt plus output and chat-template overhead under the configured `model_max_len` and account for concurrent requests consuming KV cache. These single-GPU instance choices have no multi-GPU NVLink fabric, so interpret the long prompt as a prefill/memory/KV-cache stress test, not an NVLink stress test. Compare results at the same model, token lengths, concurrency, and warm-up conditions.

## Monitor during the run

In another terminal, watch pod state and application logs:

```sh
kubectl -n llm-serving get pods -w
kubectl -n llm-serving logs deploy/triton-vllm -c triton -f
```

The port-forwarded Triton metrics endpoint is:

```sh
curl -fsS http://127.0.0.1:8002/metrics | grep -E '^vllm:|^nv_gpu'
```

For Grafana, connect to the VPC over VPN/private networking and open the internal ALB hostname from `terraform output -raw grafana_internal_alb_hostname` in the workloads root. Open the **LLM GPU Macro Profiling** dashboard. Watch the four DCGM profiling panels, ordinary GPU utilization/memory, Triton request/latency metrics, and vLLM token/latency panels. Pyroscope with Grafana Alloy profiles host CPU stacks; it does not profile CUDA kernels.

## Interpret and record results

- **TTFT** measures time to first token and reflects prompt prefill plus queue delay.
- **Inter-token latency (ITL/TPOT)** measures the spacing of generated tokens under load.
- **Token throughput** and **request throughput** show aggregate capacity; queueing and p95/p99 latency can rise as concurrency increases.
- If GPU utilization is low but latency is high, check client saturation, CPU limits, and network/storage effects. If memory or errors rise sharply, lower concurrency, output length, or `model_max_len`.
- vLLM's PagedAttention allocates KV-cache blocks as requests grow, while continuous batching admits and removes requests during generation. Repeat tests with matching prompt lengths and warm-up conditions when comparing models or instance types.

Record model alias, EC2 type, image tag, date, tokenizer, prompt/output sizes, concurrency or request rate, p50/p95/p99 latencies, TTFT, ITL, output tokens/sec, request/sec, GPU utilization/memory, and errors.

## Cost and access

Keep the inference service private and use port forwarding or an approved private client path; Grafana is accessed through its internal ALB over VPN/private networking. Do not expose Triton or Grafana publicly for testing. Run finite tests in steps and scale the GPU node group to zero when idle to avoid unnecessary EC2 charges, as described in [operation.md](operation.md).
