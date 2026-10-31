# For releases, override BASE_IMAGE with this tag's immutable @sha256 digest.
ARG BASE_IMAGE=nvcr.io/nvidia/tritonserver:26.04-vllm-python-py3
FROM ${BASE_IMAGE}
COPY autoscaling_metrics.py /opt/tritonserver/backends/vllm/utils/autoscaling_metrics.py
COPY install.py /tmp/install-autoscaling-metrics.py
RUN python3 /tmp/install-autoscaling-metrics.py && rm /tmp/install-autoscaling-metrics.py
LABEL org.opencontainers.image.title="Triton vLLM with scheduler autoscaling gauges"
