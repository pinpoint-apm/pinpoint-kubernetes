#!/usr/bin/env python3
"""Exercise a default chart install in an explicitly selected local cluster."""
import argparse
import contextlib
import json
from http.cookiejar import CookieJar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ssl
import threading
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen, build_opener, HTTPSHandler, HTTPCookieProcessor, HTTPRedirectHandler
from urllib.error import HTTPError
from hbase_local_client import LocalHBaseClient


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kubeconfig', required=True)
    parser.add_argument('--namespace', required=True)
    parser.add_argument('--release', required=True)
    parser.add_argument('--backend-namespace', help='Namespace of external HBase/Pinot for the local integration test')
    parser.add_argument('--backend-release', help='Helm release supplying those external backends')
    parser.add_argument('--stackable-hbase-cluster', help='HbaseCluster name when HBase is managed by the companion backend chart')
    parser.add_argument('--hbase-namespace', help='HBase namespace, independent of the Pinot backend namespace')
    parser.add_argument('--application-name', default='PINPOINT_DEMO_APP')
    parser.add_argument('--login-credentials', help='Local JSON file with username/password; tests Secure JWT via a loopback TLS terminator')
    parser.add_argument('--timeout', type=int, default=240)
    args = parser.parse_args()
    for name in (args.namespace, args.release, args.backend_namespace or args.namespace, args.backend_release or args.release,
                 args.stackable_hbase_cluster or args.release, args.hbase_namespace or args.namespace):
        if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', name):
            parser.error('namespace/release must be DNS labels')
    if args.timeout < 60:
        parser.error('timeout must be at least 60 seconds')
    kubeconfig = str(Path(args.kubeconfig).resolve(strict=True))
    base = ['kubectl', '--kubeconfig', kubeconfig]

    def kubectl(*command, timeout=120):
        return subprocess.check_output(base + ['-n', args.namespace] + list(command),
                                       text=True, timeout=timeout)

    config = json.loads(subprocess.check_output(base + ['config', 'view', '--minify', '-o', 'json'], text=True))
    server = config['clusters'][0]['cluster']['server']
    if urlparse(server).hostname not in ('127.0.0.1', 'localhost', '::1'):
        parser.error('local smoke testing requires a loopback Kubernetes API server')

    backend_namespace = args.backend_namespace or args.namespace
    backend_release = args.backend_release or args.release
    deadline = time.monotonic() + args.timeout
    with contextlib.ExitStack() as stack:
        def forward(service, target, namespace=None, kind="service"):
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            output = stack.enter_context(tempfile.TemporaryFile())
            process = subprocess.Popen(base + ['-n', namespace or args.namespace, 'port-forward',
                                              kind + '/' + service, f'{port}:{target}'],
                                       stdout=output, stderr=output)
            def stop():
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            stack.callback(stop)
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('port-forward failed: ' + service)
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=1):
                        return f'http://127.0.0.1:{port}'
                except OSError:
                    time.sleep(.2)
            raise TimeoutError('port-forward readiness timed out')

        web = forward(args.release + '-web', 8080)
        demo = forward(args.release + '-quickstart', 8080)
        broker = forward(backend_release + '-pinot-broker', 8099, backend_namespace)
        client = build_opener()
        if args.login_credentials:
            # A local TLS terminator validates browser Secure-cookie behavior without
            # weakening certificate verification or changing production ingress.
            directory = stack.enter_context(tempfile.TemporaryDirectory())
            cert, key = Path(directory) / 'cert.pem', Path(directory) / 'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(key), '-out', str(cert), '-days', '1',
                            '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            trust = ssl.create_default_context(cafile=str(cert))
            cookies = CookieJar()
            client = build_opener(HTTPSHandler(context=trust), HTTPCookieProcessor(cookies))

            class NoRedirect(HTTPRedirectHandler):
                def redirect_request(self, *unused):
                    return None

            def tls_proxy(upstream):
                class Proxy(BaseHTTPRequestHandler):
                    def log_message(self, *unused):
                        pass

                    def do_GET(self):
                        self.relay()

                    def do_POST(self):
                        self.relay()

                    def relay(self):
                        body = self.rfile.read(int(self.headers.get('Content-Length', 0))) or None
                        headers = {k: v for k, v in self.headers.items() if k.lower() not in ('host', 'connection')}
                        req = Request(upstream + self.path, data=body, headers=headers, method=self.command)
                        try:
                            response = build_opener(NoRedirect()).open(req, timeout=20)
                        except HTTPError as error:
                            response = error
                        with response:
                            payload = response.read()
                            self.send_response(response.code)
                            for k, v in response.headers.items():
                                if k.lower() not in ('connection', 'transfer-encoding', 'content-length'):
                                    if k.lower() == 'location':
                                        v = v.replace(upstream, 'https://127.0.0.1:' + str(self.server.server_port))
                                    self.send_header(k, v)
                            self.send_header('Content-Length', str(len(payload)))
                            self.end_headers()
                            self.wfile.write(payload)

                server = ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
                server.daemon_threads = True
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(str(cert), str(key))
                server.socket = context.wrap_socket(server.socket, server_side=True)
                threading.Thread(target=server.serve_forever, daemon=True).start()
                stack.callback(server.server_close)
                stack.callback(server.shutdown)
                return 'https://127.0.0.1:' + str(server.server_port)

            web = tls_proxy(web)
            with client.open(web + '/api/getApplicationHostInfo?durationHours=1&useCache=false', timeout=20) as response:
                if urlparse(response.url).path != '/login':
                    raise RuntimeError('Protected Web API is accessible without login')
            credentials = json.loads(Path(args.login_credentials).read_text())
            # Wrong credentials must not yield a JWT cookie.
            form = {'username': credentials['username'], 'password': 'intentionally-wrong-password'}
            client.open(Request(web + '/login', data=urlencode(form).encode()), timeout=20).close()
            if any(c.name == 'pinpointJwt' for c in cookies):
                raise RuntimeError('Invalid login produced a JWT cookie')
            form['password'] = credentials['password']
            client.open(Request(web + '/login', data=urlencode(form).encode()), timeout=20).close()
            tokens = [c for c in cookies if c.name == 'pinpointJwt']
            if len(tokens) != 1 or not tokens[0].secure or not tokens[0].has_nonstandard_attr('HttpOnly'):
                raise RuntimeError('Login must issue a Secure, HttpOnly JWT cookie')
            if tokens[0].get_nonstandard_attr('SameSite') != 'Lax':
                raise RuntimeError('Login cookie must use SameSite=Lax')
            pods = json.loads(kubectl('get', 'pods', '-l', 'app.kubernetes.io/component=web', '-o', 'json'))['items']
            for pod in pods:
                endpoint = tls_proxy(forward(pod['metadata']['name'], 8080, kind='pod'))
                with client.open(endpoint + '/api/getApplicationHostInfo?durationHours=1&useCache=false', timeout=20) as response:
                    if 'applications' not in json.load(response):
                        raise RuntimeError('JWT from one Web replica failed on another')
            print('Login rejects anonymous/invalid credentials; Secure/HttpOnly/Lax JWT works across Web replicas: OK', flush=True)

        def request(url, payload=None):
            data = None if payload is None else json.dumps(payload).encode()
            req = Request(url, data=data, headers={'Content-Type': 'application/json'})
            with client.open(req, timeout=20) as response:
                return response.status, response.read()

        assert request(web + '/')[0] == 200
        for _ in range(150):
            assert request(demo + '/getCurrentTimestamp.pinpoint')[0] == 200
        print('Web and 150 demo HTTP requests: OK', flush=True)

        required = ['inspectorStatAgent00', 'inspectorStatApp', 'uriStat', 'heatmapStatApp',
                    'systemMetricDataType', 'systemMetricTag', 'systemMetricDouble']
        counts = {table: 0 for table in required}
        pending = {}
        while time.monotonic() < deadline:
            for table in required:
                _, body = request(broker + '/query/sql', {'sql': 'SELECT COUNT(*) FROM ' + table})
                result = json.loads(body)
                # New table segments can still be assigned after Helm hooks
                # complete. Retry within the budget; incomplete queries never
                # count as successful ingestion, even if other tables work.
                rows = result.get('resultTable', {}).get('rows', [])
                if result.get('exceptions') or result.get('partialResult') or not rows:
                    counts[table] = 0
                    pending[table] = result.get('exceptions') or 'query result not ready'
                    continue
                pending.pop(table, None)
                counts[table] = rows[0][0]
            if all(counts[table] > 0 for table in required):
                break
            time.sleep(10)
        else:
            raise TimeoutError('no ingestion for: ' + ', '.join(k for k, v in counts.items() if not v)
                               + '; pending queries: ' + json.dumps(pending))
        print('Pinot records: ' + json.dumps(counts, sort_keys=True), flush=True)
        _, body = request(web + '/api/getApplicationHostInfo?durationHours=1&useCache=false')
        applications = json.loads(body)['applications']
        if not any(app['applicationName'] == args.application_name for app in applications):
            raise RuntimeError('demo application not registered in Web')
        while time.monotonic() < deadline:
            now = int(time.time() * 1000)
            query = urlencode({'applicationName': args.application_name, 'metricDefinitionId': 'heap',
                               'from': now - 1800000, 'to': now})
            _, body = request(web + '/api/inspector/applicationStat/chart?' + query)
            chart = json.loads(body)
            if any(value > 0 for metric in chart['metricValues'] for value in metric['valueList']):
                break
            time.sleep(10)
        else:
            raise TimeoutError('Inspector heap chart contains no positive samples')
        print('Web application registration and Inspector heap chart: OK', flush=True)

        # The 3.1 schema uses TraceIndex. Launch one bounded shell for both counts.
        command = '''printf "count 'TraceV2', INTERVAL => 100000; count 'TraceIndex', INTERVAL => 100000\\n" | HBASE_CONF_DIR=/tmp/pinpoint-hbase-conf timeout 90 "$HBASE_HOME/bin/hbase" shell -n 2>/dev/null'''
        if args.stackable_hbase_cluster:
            output = LocalHBaseClient(kubeconfig, args.hbase_namespace or args.namespace,
                                      args.stackable_hbase_cluster).ruby(
                "count 'TraceV2', INTERVAL => 100000\ncount 'TraceIndex', INTERVAL => 100000")
        else:
            hbase_command = base + ['-n', args.hbase_namespace or backend_namespace, 'exec', backend_release + '-hbase-0']
            output = subprocess.check_output(hbase_command + ['--', 'bash', '-c', command], text=True, timeout=120)
        rows = [int(n) for n in re.findall(r'^(\d+) row\(s\)', output, re.M)]
        if len(rows) != 2 or any(n <= 0 for n in rows):
            raise RuntimeError('HBase trace tables are empty: ' + str(rows))
        print('HBase trace rows: TraceV2=%d TraceIndex=%d' % tuple(rows), flush=True)
        pods = json.loads(kubectl('get', 'pods', '-o', 'json'))
        # Pinot's dependency uses legacy release labels, unlike the root chart.
        running = [pod for pod in pods['items'] if pod['status']['phase'] != 'Succeeded'
                   and (pod['metadata'].get('labels', {}).get('app.kubernetes.io/instance') == args.release
                        or pod['metadata'].get('labels', {}).get('release') == args.release)]
        if not running or any(not any(c['type'] == 'Ready' and c['status'] == 'True'
                                    for c in pod['status'].get('conditions', [])) for pod in running):
            raise RuntimeError('some workload pods are not Ready')
        print(f'{len(running)} workload pods Ready; local runtime smoke passed.', flush=True)


if __name__ == '__main__':
    main()
