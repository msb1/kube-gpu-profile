"""Fail closed if the base image no longer contains the reviewed upstream logger."""
import hashlib
from pathlib import Path

path = Path('/opt/tritonserver/backends/vllm/utils/metrics.py')
expected = '5a84f9b261606f154c710d9ef090df134d884ca62430a3ce57a16c6a62359778'
source = path.read_bytes()
if hashlib.sha256(source).hexdigest() != expected:
    raise SystemExit('Upstream metrics.py changed. Review backend and vLLM APIs, update tests and reviewed SHA before building.')
# Import occurs after definitions. The upstream factory resolves this class at call time.
path.write_bytes(source + b'\nfrom utils.autoscaling_metrics import install as _install_autoscaling_metrics\n_install_autoscaling_metrics(globals())\n')
