"""SSE-aware Locust workload for the Triton/vLLM OpenAI chat endpoint.

TTFT is measured to the first non-empty text delta. Stream chunk intervals are
reported as a TTFT-adjacent UX signal, not true token-level ITL: OpenAI SSE
chunks are not guaranteed to contain exactly one generated token.
"""

import json
import os
import time

from locust import HttpUser, LoadTestShape, between, task


MODEL = os.getenv("MODEL", "qwen25_7b_instruct")
MAX_TOKENS = int(os.getenv("MAX_TOKENS", "256"))
API_KEY = os.getenv("API_KEY")
PROMPT = os.getenv(
    "LOCUST_PROMPT",
    "Explain how containerization works, including its benefits and tradeoffs.",
)


class TritonLLMUser(HttpUser):
    """One simulated user repeatedly sends a streamed chat completion."""

    wait_time = between(
        float(os.getenv("WAIT_TIME_MIN", "2")),
        float(os.getenv("WAIT_TIME_MAX", "5")),
    )

    def _record_metric(self, name: str, value_ms: float, response_length: int = 0) -> None:
        # Separate Locust request names keep custom latency distributions
        # inspectable without confusing them with /v1 request latency.
        self.environment.events.request.fire(
            request_type="LLM metric",
            name=name,
            response_time=value_ms,
            response_length=response_length,
            exception=None,
            context={"model": MODEL},
        )

    @task
    def stream_chat_completion(self) -> None:
        payload = {
            "model": MODEL,
            "messages": [{"role": "user", "content": PROMPT}],
            "temperature": 0.2,
            "max_tokens": MAX_TOKENS,
            "stream": True,
        }
        headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
        if API_KEY:
            headers["Authorization"] = f"Bearer {API_KEY}"
        request_started = time.perf_counter()
        first_text_ms = None
        previous_text_chunk_at = None
        chunk_intervals_ms = []

        with self.client.post(
            "/v1/chat/completions",
            json=payload,
            headers=headers,
            stream=True,
            catch_response=True,
            name="/v1/chat/completions (stream)",
        ) as response:
            if response.status_code != 200:
                response.failure(f"HTTP {response.status_code}: {response.text[:500]}")
                return

            try:
                for raw_line in response.iter_lines(decode_unicode=True):
                    if not raw_line:
                        continue
                    if isinstance(raw_line, bytes):
                        line = raw_line.decode("utf-8", errors="replace").strip()
                    else:
                        line = raw_line.strip()
                    if not line.startswith("data:"):
                        continue

                    data_text = line[len("data:") :].strip()
                    if data_text == "[DONE]":
                        break
                    try:
                        event = json.loads(data_text)
                    except json.JSONDecodeError:
                        continue

                    choices = event.get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}
                    content = delta.get("content")
                    if not isinstance(content, str) or not content:
                        continue

                    now = time.perf_counter()
                    if first_text_ms is None:
                        first_text_ms = (now - request_started) * 1000
                    elif previous_text_chunk_at is not None:
                        chunk_intervals_ms.append((now - previous_text_chunk_at) * 1000)
                    previous_text_chunk_at = now

            except (OSError, ValueError) as exc:
                response.failure(f"Failed while reading SSE stream: {exc}")
                return

            if first_text_ms is None:
                response.failure("HTTP 200 response contained no streamed text deltas")
                return

            self._record_metric("TTFT (first text delta)", first_text_ms)
            if chunk_intervals_ms:
                mean_chunk_interval_ms = sum(chunk_intervals_ms) / len(chunk_intervals_ms)
                self._record_metric(
                    "Mean inter-content-chunk interval (not token ITL)",
                    mean_chunk_interval_ms,
                    response_length=len(chunk_intervals_ms),
                )
            response.success()


class CapacityStepShape(LoadTestShape):
    """Add a fixed number of users at each interval, then hold at the cap."""

    step_users = max(1, int(os.getenv("STEP_USERS", "5")))
    step_seconds = max(1, int(os.getenv("STEP_SECONDS", "30")))
    max_users = max(1, int(os.getenv("MAX_USERS", "100")))
    hold_seconds = max(0, int(os.getenv("HOLD_SECONDS", "120")))
    spawn_seconds = max(1, int(os.getenv("STEP_SPAWN_SECONDS", "5")))

    def tick(self):
        elapsed = self.get_run_time()
        ramp_steps = (self.max_users + self.step_users - 1) // self.step_users
        if elapsed >= ramp_steps * self.step_seconds + self.hold_seconds:
            return None

        completed_steps = int(elapsed // self.step_seconds)
        target_users = min((completed_steps + 1) * self.step_users, self.max_users)
        spawn_rate = self.step_users / self.spawn_seconds
        return target_users, max(spawn_rate, 0.1)
