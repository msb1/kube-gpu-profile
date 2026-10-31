"""CPU contract tests: no GPU or Triton installation required."""
import importlib.util
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location('extension', Path(__file__).resolve().parents[1] / 'images/triton-metrics/autoscaling_metrics.py')
extension = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extension)

class Gauge:
    def __init__(self, **kwargs): self.value = 0
    def set(self, value): self.value = value

class Family:
    GAUGE = 2
    def __init__(self, **kwargs): self.name = kwargs['name']
    def Metric(self, **kwargs): return Gauge(**kwargs)

class Base:
    def __init__(self, labels, log_logger, config, engine):
        self.log_logger = log_logger
        self.calls = []
    def record(self, *args): self.calls.append(args)
    def finalize(self): self.finalized = True

class Contract(unittest.TestCase):
    def setUp(self):
        module = ModuleType('vllm.v1.metrics.stats')
        module.SchedulerStats = lambda: SimpleNamespace(kv_cache_usage=0.0, num_waiting_reqs=0)
        self.previous = sys.modules.get(module.__name__)
        sys.modules[module.__name__] = module
        namespace = dict(pb_utils=SimpleNamespace(MetricFamily=Family), VllmStatLogger=Base)
        extension.install(namespace)
        self.logger = namespace['VllmStatLogger']({}, SimpleNamespace(log_error=lambda _: None), None, 0)
    def tearDown(self):
        if self.previous is None: sys.modules.pop('vllm.v1.metrics.stats', None)
        else: sys.modules['vllm.v1.metrics.stats'] = self.previous
    def test_scheduler_only_update_preserves_fraction_and_queue(self):
        self.logger.record(SimpleNamespace(kv_cache_usage=.81, num_waiting_reqs=5), None)
        self.assertEqual([g.value for g in self.logger._gauges[:2]], [.81, 5])
        self.assertGreater(self.logger._gauges[2].value, 0)
        self.assertEqual(len(self.logger.calls), 1)
    def test_idle_resets_gauges(self):
        self.logger.record(SimpleNamespace(kv_cache_usage=.9, num_waiting_reqs=8), None)
        self.logger.record(SimpleNamespace(kv_cache_usage=0, num_waiting_reqs=0), None)
        self.assertEqual([g.value for g in self.logger._gauges[:2]], [0, 0])
    def test_missing_invalid_stats_do_not_refresh_timestamp(self):
        for stats in [None, SimpleNamespace(kv_cache_usage=float('nan'), num_waiting_reqs=3), SimpleNamespace(kv_cache_usage=80, num_waiting_reqs=3)]:
            self.logger.record(stats, None)
        self.assertEqual(self.logger._gauges[2].value, 0)
        self.assertEqual(len(self.logger.calls), 3)
    def test_finalize_releases_metrics(self):
        self.logger.finalize()
        self.assertTrue(self.logger.finalized)
        self.assertEqual(self.logger._gauges, [])
        self.assertEqual(self.logger._families, [])

if __name__ == '__main__': unittest.main()
