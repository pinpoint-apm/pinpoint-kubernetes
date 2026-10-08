#!/usr/bin/env python3
"""Create the local demonstration namespace, random credentials and a TLS Secret."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
from urllib.parse import urlparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kubeconfig', required=True)
    parser.add_argument('--output-dir', default='/tmp/pinpoint-production-demo')
    args = parser.parse_args()
    base = ['kubectl', '--kubeconfig', str(Path(args.kubeconfig).resolve(strict=True))]
    config = json.loads(subprocess.check_output(base + ['config', 'view', '--minify', '-o', 'json'], text=True))
    if urlparse(config['clusters'][0]['cluster']['server']).hostname not in ('127.0.0.1', 'localhost', '::1'):
        parser.error('This example requires a loopback local test cluster')
    os.umask(0o077)
    output = Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    output.chmod(0o700)
    def apply(resource):
        subprocess.run(base + ['apply', '-f', '-'], input=json.dumps(resource), text=True, check=True)
    apply({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': 'pinpoint'}})
    # Retain credentials on reruns; replacing a database Secret is not password rotation.
    credential_file = output / 'credentials.json'
    if credential_file.exists():
        credentials = json.loads(credential_file.read_text())
    else:
        credentials = {key: secrets.token_hex(24) for key in ('mysql-root', 'mysql-user', 'redis', 'jwt', 'admin')}
        credential_file.write_text(json.dumps(credentials))
    credential_file.chmod(0o600)
    def secret(namespace, name, data, kind='Opaque'):
        apply({'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'namespace': namespace, 'name': name},
               'type': kind, 'data': {key: base64.b64encode(value.encode()).decode() for key, value in data.items()}})
    # Separate backend and application Secrets even in one namespace: Web and
    # Collector never need the database root credential.
    secret('pinpoint', 'pinpoint-services-mysql',
           {'mysql-password': credentials['mysql-user'], 'mysql-root-password': credentials['mysql-root']})
    secret('pinpoint', 'pinpoint-mysql', {'mysql-password': credentials['mysql-user']})
    secret('pinpoint', 'pinpoint-redis', {'redis-password': credentials['redis']})
    secret('pinpoint', 'pinpoint-login',
           {'jwt-secret': credentials['jwt'], 'admin': 'admin:' + credentials['admin']})
    login = output / 'login.json'
    login.write_text(json.dumps({'username': 'admin', 'password': credentials['admin']}))
    login.chmod(0o600)
    key, cert = output / 'tls.key', output / 'tls.crt'
    certificate_matches = False
    if key.exists() and cert.exists():
        existing = subprocess.run(['openssl', 'x509', '-in', str(cert), '-noout', '-ext', 'subjectAltName'],
                                  capture_output=True, text=True, check=True)
        names = {name.strip() for line in existing.stdout.splitlines()[1:] for name in line.split(',')}
        certificate_matches = {'DNS:pinpoint.localhost', 'DNS:localhost', 'IP Address:127.0.0.1'} <= names
    if not certificate_matches:
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '30',
                        '-keyout', str(key), '-out', str(cert), '-subj', '/CN=pinpoint.localhost',
                        '-addext', 'subjectAltName=DNS:pinpoint.localhost,DNS:localhost,IP:127.0.0.1'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    key.chmod(0o600)
    secret('pinpoint', 'pinpoint-web-tls', {'tls.key': key.read_text(), 'tls.crt': cert.read_text()}, 'kubernetes.io/tls')
    print(f'Local credentials retained privately in {output}; no credentials written to the repository.')


if __name__ == '__main__':
    main()
