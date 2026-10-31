"""Project-owned extension to the r26.04 Triton vLLM scheduler stat logger.

Uses Triton's existing metric endpoint. Never derives KV usage from DCGM memory.
The upstream logger, token counters, and latency histograms remain intact.
"""
import math
import time


def install(namespace):
    pb_utils = namespace["pb_utils"]
    base = namespace["VllmStatLogger"]

    class AutoscalingStatLogger(base):
        def __init__(self, labels, log_logger, vllm_config, engine_index):
            # Validate before starting upstream's non-daemon reporting thread.
            if engine_index != 0:
                raise ValueError("Autoscaling extension supports one engine per replica")
            from vllm.v1.metrics.stats import SchedulerStats
            stats = SchedulerStats()
            for field in ("kv_cache_usage", "num_waiting_reqs"):
                if not hasattr(stats, field):
                    raise RuntimeError(f"Unsupported vLLM SchedulerStats: missing {field}")
            self._families = []
            self._gauges = []
            for name, description in (
                ("llm_kv_cache_usage_ratio", "Scheduler KV cache utilization, fraction 0..1."),
                ("llm_num_requests_waiting", "Requests waiting inside the vLLM scheduler."),
                ("llm_scheduler_update_timestamp_seconds", "Unix time of last valid scheduler update."),
            ):
                family = pb_utils.MetricFamily(name=name, description=description, kind=pb_utils.MetricFamily.GAUGE)
                self._families.append(family)
                self._gauges.append(family.Metric(labels=labels))
            super().__init__(labels, log_logger, vllm_config, engine_index)

        def record(self, scheduler_stats, iteration_stats, mm_cache_stats=None, engine_idx=0):
            if scheduler_stats is not None:
                usage = float(scheduler_stats.kv_cache_usage)
                waiting = float(scheduler_stats.num_waiting_reqs)
                if math.isfinite(usage) and 0 <= usage <= 1 and math.isfinite(waiting) and waiting >= 0:
                    # Timestamp written last: an invalid update never looks fresh.
                    for gauge, value in zip(self._gauges, (usage, waiting, time.time())):
                        gauge.set(value)
                else:
                    self.log_logger.log_error("Invalid autoscaling scheduler statistics; retaining last valid timestamp")
            super().record(scheduler_stats, iteration_stats, mm_cache_stats, engine_idx)

        def finalize(self):
            super().finalize()
            # Metric instances must be released before their MetricFamilies.
            self._gauges.clear()
            self._families.clear()

    namespace["VllmStatLogger"] = AutoscalingStatLogger
