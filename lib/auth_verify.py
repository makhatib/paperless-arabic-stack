#!/usr/bin/env python3
"""Live checks only. Deliberately does not claim browser login was tested."""
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from auth_config import urls


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check(env):
    u = urls(env)
    context = ssl.create_default_context()
    if env['PAS_TARGET'] == 'homelab':
        context.load_verify_locations('auth/tls/ca.crt')
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=context), NoRedirect())

    def get(url, headers=None):
        try:
            with opener.open(urllib.request.Request(url, headers=headers or {}), timeout=10) as r:
                return r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()

    for attempt in range(36):
        try:
            status, _, body = get(u['auth'] + '/application/o/paperless/.well-known/openid-configuration')
            if status == 200:
                discovery = json.loads(body)
                assert discovery['issuer'] == u['auth'] + '/application/o/paperless/'
                assert discovery['authorization_endpoint'].startswith(u['auth'] + '/')
                break
        except (OSError, ValueError, AssertionError):
            pass
        if attempt == 35:
            raise RuntimeError('Trusted HTTPS / OIDC discovery failed; check DNS, certificate trust and Authentik provisioning')
        time.sleep(5)
    code, _, _ = get(u['docs'])
    if code not in (200, 301, 302):
        raise RuntimeError('Paperless HTTPS route did not answer')
    if env['PAS_AI_MODE'] != 'none':
        for path in ['/', '/api/documents', '/static/probe.js', '/ws', '/anything']:
            for headers in [{}, {'Cookie': 'authentik_proxy=invalid'},
                            {'X-authentik-username': 'akadmin', 'X-Forwarded-User': 'akadmin',
                             'X-Forwarded-Host': 'localhost', 'X-Forwarded-Proto': 'http',
                             'Authorization': 'Bearer invalid'}]:
                code, response_headers, _ = get(u['ai'] + path, headers)
                if code not in (302, 303, 401, 403):
                    raise RuntimeError(f'GPT anonymous request did not receive an authentication denial ({code})')
                if code in (302, 303):
                    target = response_headers.get('Location', '')
                    if not (target.startswith(u['auth'] + '/') or target.startswith('/outpost.goauthentik.io/')
                            or target.startswith(u['ai'] + '/outpost.goauthentik.io/')):
                        raise RuntimeError('Unexpected GPT authentication redirect')
    ids = subprocess.check_output(['docker', 'compose', 'ps', '-q'], text=True).split()
    if not ids:
        raise RuntimeError('No running containers')
    containers = json.loads(subprocess.check_output(['docker', 'inspect', *ids]))
    names = set()
    for container in containers:
        name = container['Config']['Labels']['com.docker.compose.service']
        names.add(name)
        published = container['HostConfig'].get('PortBindings') or {}
        if name != 'traefik' and any(published.values()):
            raise RuntimeError('Published backend port detected: ' + name)
        if container['State']['Status'] != 'running':
            raise RuntimeError('Service not running: ' + name)
        health = container['State'].get('Health', {}).get('Status')
        if health and health != 'healthy':
            raise RuntimeError('Service not healthy: ' + name)
    required = {'webserver', 'auth-db', 'authentik', 'auth-worker', 'traefik'}
    if env['PAS_AI_MODE'] != 'none':
        required.add('paperless-gpt')
    if not required <= names:
        raise RuntimeError('Required services are missing')
    print('PASS: trusted TLS, OIDC discovery, route denial and live port isolation')


if __name__ == '__main__':
    try:
        check(os.environ)
    except Exception as exc:
        print('FAIL: ' + str(exc), file=sys.stderr)
        sys.exit(1)
