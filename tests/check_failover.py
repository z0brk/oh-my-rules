import http.client
import json
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parent.parent
template = json.loads(subprocess.check_output([
    'ruby', '-ryaml', '-rjson', '-e',
    'puts JSON.generate(YAML.load_file(ARGV[0]))', str(ROOT / 'config-template.yml'),
]))
names = ['AI自动', '优质自动', 'AI优选', '优质优选', 'AI备用', '优质备用']


class MockProxy(socketserver.StreamRequestHandler):
    def handle(self):
        request = self.rfile.readline().decode('ascii')
        while self.rfile.readline() not in (b'\r\n', b'\n', b''):
            pass
        if request.startswith('CONNECT '):
            self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
            self.wfile.flush()
            request = self.rfile.readline().decode('ascii')
            while self.rfile.readline() not in (b'\r\n', b'\n', b''):
                pass
        service = 'ai' if '/ai' in request else 'quality'
        status = self.server.status[service]
        time.sleep(self.server.delay)
        self.wfile.write(
            f'HTTP/1.1 {status} Test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.encode()
        )


class UnixHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.host)


def fetch(sock, endpoint):
    conn = UnixHTTP(str(sock), timeout=2)
    try:
        conn.request('GET', endpoint, headers={'Host': 'localhost'})
        response = conn.getresponse()
        assert response.status == 200, (endpoint, response.status)
        return json.loads(response.read())
    finally:
        conn.close()


def wait_for(sock, expected, process):
    deadline = time.monotonic() + 12
    actual = {}
    while time.monotonic() < deadline:
        assert process.poll() is None, 'Test core exited unexpectedly'
        try:
            proxies = fetch(sock, '/proxies')['proxies']
            actual = {name: proxies[name]['now'] for name in expected}
            if actual == expected:
                return proxies
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.1)
    raise AssertionError(f'Expected {expected}, got {actual}')


def run(binary, provider_backups):
    servers = []
    process = None
    try:
        for delay in [0.005, 0.2, 0.005]:
            server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), MockProxy)
            server.daemon_threads = True
            server.status = {'ai': 401, 'quality': 200}
            server.delay = delay
            threading.Thread(target=server.serve_forever, daemon=True).start()
            servers.append(server)
        primary, slow, fast = servers
        nodes = [
            {'name': name, 'type': 'http', 'server': '127.0.0.1', 'port': server.server_address[1]}
            for name, server in [('[优质] mock', primary), ('普通 01 慢速 mock', slow),
                                 ('普通 02 快速 mock', fast), ('流量 mock', fast), ('Free mock', fast)]
        ]
        groups = json.loads(json.dumps([
            g for g in template['proxy-groups'] if g['name'] in names
        ]))
        for group in groups:
            service = 'ai' if group['name'].startswith('AI') else 'quality'
            group.update(url=f'http://probe.invalid/{service}', interval=1, timeout=500)
        with tempfile.TemporaryDirectory(prefix='mihomo-failover-') as directory:
            root = Path(directory)
            sock = root / 'controller.sock'
            config = {
                'log-level': 'error', 'ipv6': False,
                'proxies': nodes[:1] if provider_backups else nodes,
                'proxy-providers': {'fixture': {'type': 'inline', 'payload': nodes[1:]}}
                if provider_backups else {},
                'proxy-groups': groups, 'rules': ['MATCH,REJECT'],
            }
            source = root / 'config.json'
            source.write_text(json.dumps(config, ensure_ascii=False))
            with (root / 'core.log').open('w+') as log:
                process = subprocess.Popen([
                    binary, '-d', directory, '-f', str(source), '-ext-ctl-unix', str(sock),
                ], stdout=log, stderr=subprocess.STDOUT)
                proxies = wait_for(sock, {
                    'AI自动': 'AI优选', '优质自动': '优质优选',
                    'AI备用': '普通 02 快速 mock', '优质备用': '普通 02 快速 mock',
                }, process)
                for name, preferred, backup in [('AI自动', 'AI优选', 'AI备用'), ('优质自动', '优质优选', '优质备用')]:
                    assert proxies[name]['all'] == [preferred, backup]
                    members = proxies[backup]['all']
                    assert members == ['普通 01 慢速 mock', '普通 02 快速 mock'], members
                    assert proxies[preferred]['all'] == ['[优质] mock']

                primary.status = {'ai': 503, 'quality': 503}
                wait_for(sock, {
                    'AI自动': 'AI备用', '优质自动': '优质备用',
                    'AI备用': '普通 02 快速 mock', '优质备用': '普通 02 快速 mock',
                }, process)

                fast.status = {'ai': 403, 'quality': 503}
                wait_for(sock, {
                    'AI自动': 'AI备用', '优质自动': '优质备用',
                    'AI备用': '普通 01 慢速 mock', '优质备用': '普通 01 慢速 mock',
                }, process)
                slow.status['ai'] = 403
                wait_for(sock, {'AI自动': 'AI优选', '优质自动': '优质备用'}, process)

                fast.status = {'ai': 401, 'quality': 200}
                slow.status['ai'] = 401
                wait_for(sock, {
                    'AI自动': 'AI备用', '优质自动': '优质备用',
                    'AI备用': '普通 02 快速 mock', '优质备用': '普通 02 快速 mock',
                }, process)

                primary.status = {'ai': 401, 'quality': 200}
                wait_for(sock, {'AI自动': 'AI优选', '优质自动': '优质优选'}, process)
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    binary = sys.argv[1] if len(sys.argv) > 1 else 'mihomo'
    for provider_backups in [False, True]:
        run(binary, provider_backups)
    print('PASS: preferred pools, fastest backup, backup failover, AI 403 rejection, recovery, provider/flattened nodes')
