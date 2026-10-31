#!/usr/bin/env python3
"""Exercise the real Terraform-rendered NGINX gateway without AWS or Docker.

Run with --nginx /path/to/nginx --terraform /path/to/terraform.
Only synthetic keys and mock inference responses are used. On systems without a
second loopback address, two DNS upstream names/ports model the ready backends.
"""
import argparse
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
KEY = 'Example_aA_' + '1234567890' * 4
KEY2 = 'Rotate_bB_' + '9876543210' * 4


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class DNS:
    def __init__(self, addresses):
        self.addresses = addresses
        self.removed_names = set()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(('127.0.0.1', 0))
        self.port = self.sock.getsockname()[1]
        self.sock.settimeout(.2)
        self.stopped = False
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stopped:
            try:
                packet, peer = self.sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            end = 12
            labels = []
            while packet[end]:
                labels.append(packet[end + 1:end + 1 + packet[end]].decode())
                end += packet[end] + 1
            end += 5
            question = packet[12:end]
            addresses = [] if '.'.join(labels) in self.removed_names else self.addresses
            answers = b''.join(b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 1, 4) + socket.inet_aton(ip) for ip in addresses)
            response = packet[:2] + struct.pack('!HHHHH', 0x8180 if addresses else 0x8183, 1, len(addresses), 0, 0) + question + answers
            self.sock.sendto(response, peer)

    def close(self):
        self.stopped = True
        self.thread.join(1)
        self.sock.close()


class Backend(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    calls = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.handle_api()

    def do_POST(self):
        self.handle_api()

    def handle_api(self):
        size = int(self.headers.get('Content-Length', 0))
        if size:
            self.rfile.read(size)
        backend = "%s:%s" % self.server.server_address
        Backend.calls.append((backend, self.headers.get('Authorization'), self.path))
        if self.path.endswith('/stream'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            for value in ['data: ' + backend + '\n\n', 'data: [DONE]\n\n']:
                payload = value.encode()
                self.wfile.write(('%x\r\n' % len(payload)).encode() + payload + b'\r\n')
                self.wfile.flush()
                time.sleep(.4)
            self.wfile.write(b'0\r\n\r\n')
            self.wfile.flush()
        else:
            body = json.dumps({'backend': backend}).encode()
            self.send_response(503 if self.path.endswith('/fail') else 200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)


class GatewayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='inference-gateway-')
        cls.path = Path(cls.tmp.name)
        backend_port = free_port()
        cls.backends = [ThreadingHTTPServer(('127.0.0.1', backend_port), Backend)]
        try:
            cls.backends.append(ThreadingHTTPServer(('127.0.0.2', backend_port), Backend))
        except OSError:
            cls.backends.append(ThreadingHTTPServer(('127.0.0.1', free_port()), Backend))
        cls.two_names = cls.backends[1].server_address[0] == '127.0.0.1'
        for server in cls.backends:
            server.daemon_threads = True
            threading.Thread(target=server.serve_forever, daemon=True).start()
        cls.dns = DNS(list(dict.fromkeys(server.server_address[0] for server in cls.backends)))
        cls.port = free_port()
        # Terraform itself renders both checked-in templates. No provider, state,
        # cluster, cloud credentials or real secrets are involved in this module.
        expression = 'jsonencode({config=templatefile(' + json.dumps(str(ROOT / 'workloads/gateway/nginx.conf.tftpl')) + ',{dns_resolver=' + json.dumps('127.0.0.1:' + str(cls.dns.port)) + ',backend_host="triton.test",stream_timeout=3}),auth=templatefile(' + json.dumps(str(ROOT / 'workloads/gateway/auth.conf.tftpl')) + ',{api_keys=' + json.dumps([KEY, KEY2]) + '})})'
        result = subprocess.run([ARGS.terraform, 'console', '-no-color'], input=expression + '\n', text=True, cwd=cls.path, capture_output=True, check=True)
        rendered = json.loads(json.loads(result.stdout.strip()))
        auth = cls.path / 'auth.conf'
        auth.write_text(rendered['auth'])
        config = rendered['config'].replace('/etc/nginx/secrets/auth.conf', str(auth)).replace('listen 8080;', 'listen %s;' % cls.port).replace(':9000 resolve;', ':%s resolve;' % backend_port).replace('/tmp/', str(cls.path) + '/').replace('/dev/stdout', str(cls.path / 'access.log')).replace('/dev/stderr', str(cls.path / 'error.log'))
        if cls.two_names:
            config = config.replace('server triton.test:%s resolve;' % backend_port, 'server triton.test:%s resolve;\n    server triton-two.test:%s resolve;' % (backend_port, cls.backends[1].server_address[1]))
        (cls.path / 'logs').mkdir()
        (cls.path / 'nginx.conf').write_text(config)
        cls.command = [ARGS.nginx, '-p', str(cls.path) + '/', '-c', str(cls.path / 'nginx.conf')]
        check = subprocess.run(cls.command + ['-t'], capture_output=True, text=True)
        if check.returncode:
            raise RuntimeError(check.stderr)
        cls.process = subprocess.Popen(cls.command + ['-g', 'daemon off;'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                status, _ = cls.request('/healthz')
                if status == 200:
                    # Let asynchronous upstream DNS resolve before API checks.
                    time.sleep(.2)
                    return
            except OSError:
                pass
            if cls.process.poll() is not None:
                raise RuntimeError(cls.process.stderr.read().decode())
            time.sleep(.05)
        raise RuntimeError('NGINX did not become ready')

    @classmethod
    def request(cls, path='/v1/models', key=None, connection=None):
        own = connection is None
        conn = connection or http.client.HTTPConnection('127.0.0.1', cls.port, timeout=5)
        headers = {} if key is None else {'Authorization': key}
        conn.request('GET', path, headers=headers)
        response = conn.getresponse()
        result = response.status, response.read()
        if own:
            conn.close()
        return result

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)
        cls.process.stderr.close()
        cls.dns.close()
        for server in cls.backends:
            server.shutdown()
            server.server_close()
        cls.tmp.cleanup()

    def test_missing_wrong_and_wrong_case_keys_are_rejected_before_backend(self):
        before = len(Backend.calls)
        for key in [None, 'Bearer wrong', 'Bearer ' + KEY.swapcase(), 'Bearer ' + KEY + 'suffix']:
            self.assertEqual(self.request(key=key)[0], 401)
        self.assertEqual(len(Backend.calls), before)

    def test_overlap_keys_and_scheme_casing(self):
        for key in ['Bearer ' + KEY, 'bearer ' + KEY, 'Bearer ' + KEY2]:
            self.assertEqual(self.request(key=key)[0], 200)
        self.assertIsNone(Backend.calls[-1][1], 'Authorization must be stripped upstream')

    def test_probe_and_non_api_paths(self):
        self.assertEqual(self.request('/healthz')[0], 200)
        self.assertEqual(self.request('/metrics', 'Bearer ' + KEY)[0], 404)

    def test_no_replay_on_upstream_failure(self):
        before = len(Backend.calls)
        self.assertEqual(self.request('/v1/fail', 'Bearer ' + KEY)[0], 503)
        self.assertEqual(len(Backend.calls) - before, 1)

    def test_stream_is_delivered_incrementally(self):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        start = time.monotonic()
        conn.request('POST', '/v1/stream', body=b'{}', headers={'Authorization': 'Bearer ' + KEY})
        response = conn.getresponse()
        self.assertEqual(response.status, 200)
        self.assertTrue(response.readline().startswith(b'data: 127.'))
        self.assertLess(time.monotonic() - start, .35, 'First event was buffered behind the second event')
        self.assertIn(b'[DONE]', response.read())
        conn.close()

    def test_reused_client_connection_reaches_both_ready_backends(self):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        seen = {json.loads(self.request(key='Bearer ' + KEY, connection=conn)[1])['backend'] for _ in range(12)}
        conn.close()
        self.assertEqual(seen, {'%s:%s' % server.server_address for server in self.backends})

    def test_z_dns_removal_stops_new_requests_to_removed_backend(self):
        if self.two_names:
            self.dns.removed_names.add('triton-two.test')
        else:
            self.dns.addresses = ['127.0.0.1']
        time.sleep(7)
        for _ in range(8):
            status, body = self.request(key='Bearer ' + KEY)
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)['backend'], '%s:%s' % self.backends[0].server_address)

    def test_secrets_not_in_access_log(self):
        self.request('/v1/models?synthetic_prompt=do-not-log-this', 'Bearer ' + KEY)
        log = (self.path / 'access.log').read_text()
        for secret in [KEY, KEY2, 'do-not-log-this']:
            self.assertNotIn(secret, log)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--nginx', required=True)
    parser.add_argument('--terraform', default='terraform')
    ARGS, remaining = parser.parse_known_args()
    unittest.main(argv=[__file__] + remaining)
