#!/usr/bin/env python3
"""Verify TLS and Web login through the local example's real ingress controller."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import urlencode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=18443)
    parser.add_argument('--host', choices=['localhost', 'pinpoint.localhost'], default='localhost')
    parser.add_argument('--credentials', default='/tmp/pinpoint-production-demo/login.json')
    parser.add_argument('--ca', default='/tmp/pinpoint-production-demo/tls.crt')
    parser.add_argument('--application-name')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('port must be between 1 and 65535')
    credentials = json.loads(Path(args.credentials).read_text())
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='pinpoint-ingress-check-') as directory:
        cookies = Path(directory) / 'cookies'
        headers = Path(directory) / 'headers'
        base = ['curl', '--silent', '--show-error', '--noproxy', '*', '--max-time', '20',
                '--resolve', f'{args.host}:{args.port}:127.0.0.1', '--cacert', args.ca,
                '--cookie', str(cookies), '--cookie-jar', str(cookies), '--dump-header', str(headers),
                '--write-out', '\n%{http_code}']
        def request(path, form=None):
            command = base + [f'https://{args.host}:{args.port}{path}']
            if form is not None:
                command += ['--header', 'Content-Type: application/x-www-form-urlencoded', '--data-binary', '@-']
            response = subprocess.check_output(command, input=None if form is None else urlencode(form), text=True)
            body, status = response.rsplit('\n', 1)
            return int(status), body
        status, _ = request('/login')
        assert status == 200, f'Login page returned HTTP {status}'
        status, _ = request('/api/getApplicationHostInfo?durationHours=1&useCache=false')
        assert status in (302, 303) and '/login' in headers.read_text(), 'Anonymous API was not redirected to login'
        request('/login', {'username': credentials['username'], 'password': 'intentionally-wrong-password'})
        assert 'pinpointJwt' not in cookies.read_text(), 'Invalid credentials issued a JWT'
        request('/login', credentials)
        set_cookie = [line.lower() for line in headers.read_text().splitlines()
                      if line.lower().startswith('set-cookie: pinpointjwt=')]
        assert len(set_cookie) == 1, 'Valid credentials did not issue exactly one JWT'
        assert all(flag in set_cookie[0] for flag in ('secure', 'httponly', 'samesite=lax')), 'Cookie flags are incomplete'
        status, body = request('/api/getApplicationHostInfo?durationHours=1&useCache=false')
        assert status == 200, f'Authenticated API returned HTTP {status}'
        applications = json.loads(body)['applications']
        if args.application_name:
            assert any(item['applicationName'] == args.application_name for item in applications), 'Demo application not registered'
        print('Real Traefik ingress: verified TLS, login HTTP 200, anonymous/invalid rejection, Secure/HttpOnly/Lax JWT and authenticated API passed.')


if __name__ == '__main__':
    main()
