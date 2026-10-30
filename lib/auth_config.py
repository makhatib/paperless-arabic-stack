#!/usr/bin/env python3
"""Build security configuration using the standard library; never log secrets."""
import copy
import ipaddress
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
from urllib.parse import urlsplit


def save(path, value):
    path = Path(path)
    tmp = path.with_name(path.name + '.tmp')
    with tmp.open('w') as f:
        os.chmod(tmp, 0o600)
        json.dump(value, f, indent=2, sort_keys=True)
        f.write('\n')
    tmp.replace(path)


def urls(env):
    if env['PAS_TARGET'] == 'vps':
        domain = env['PAS_DOMAIN']
        return {k: 'https://' + env[sub] + '.' + domain for k, sub in
                [('docs', 'PAS_DOCS_SUB'), ('ai', 'PAS_AI_SUB'), ('auth', 'PAS_AUTH_SUB')]}
    ip = str(ipaddress.IPv4Address(env['PAS_LAN_IP']))
    return {'docs': 'https://' + ip, 'auth': 'https://' + ip + ':8443',
            'ai': 'https://' + ip + ':8444'}


def render(base, env, root):
    """Preserve OCR/AI services and volumes; replace only network/auth surfaces."""
    base = copy.deepcopy(base)
    u = urls(env)
    lan = env['PAS_TARGET'] == 'homelab'
    services = base['services']
    services.pop('traefik', None)
    for service in services.values():
        service.pop('ports', None)
        service.pop('labels', None)
    # Separate the database, document converters, AI backend and ingress paths.
    membership = {'db': ['database'], 'broker': ['database'],
                  'gotenberg': ['converters'], 'tika': ['converters'],
                  'webserver': ['database', 'converters', 'documents', 'ngx-edge', 'egress'],
                  'paperless-gpt': ['documents', 'ai', 'gpt-edge', 'egress'],
                  'ollama': ['ai', 'egress']}
    for name, service in services.items():
        service['networks'] = membership[name]
    base['networks'] = {n: {'internal': True} for n in
                        ['database', 'converters', 'documents', 'ai', 'ngx-edge', 'gpt-edge', 'auth-edge', 'identity']}
    base['networks']['egress'] = {}
    web = services['webserver']
    web['environment'].update({
        'PAPERLESS_URL': u['docs'],
        'PAPERLESS_APPS': 'allauth.socialaccount.providers.openid_connect',
        'PAPERLESS_SOCIALACCOUNT_PROVIDERS': json.dumps({'openid_connect': {
            'OAUTH_PKCE_ENABLED': True, 'SCOPE': ['openid', 'profile', 'email'],
            'APPS': [{'provider_id': 'authentik', 'name': 'Authentik',
                      'client_id': env['PAS_OIDC_CLIENT_ID'], 'secret': env['PAS_OIDC_CLIENT_SECRET'],
                      'settings': {'server_url': u['auth'] + '/application/o/paperless/',
                                   'token_auth_method': 'client_secret_basic'}}]}}),
        'PAPERLESS_ACCOUNT_ALLOW_SIGNUPS': 'false',
        'PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS': 'false',
        'PAPERLESS_SOCIAL_AUTO_SIGNUP': 'false',
        'PAPERLESS_DISABLE_REGULAR_LOGIN': 'false',
        'PAPERLESS_ENABLE_HTTP_REMOTE_USER': 'false',
        'PAPERLESS_SESSION_COOKIE_AGE': '28800',
        'PAPERLESS_COOKIE_PREFIX': 'paperless_',
        'PAPERLESS_PROXY_SSL_HEADER': '["HTTP_X_FORWARDED_PROTO", "https"]',
        'PAPERLESS_ACCOUNT_DEFAULT_HTTP_PROTOCOL': 'https',
    })
    if 'paperless-gpt' in services:
        services['paperless-gpt']['environment']['PAPERLESS_PUBLIC_URL'] = u['docs']
    # Public CA trust remains active; LAN adds only our own CA, never verify=False.
    if lan:
        web['volumes'].append({'type': 'bind', 'source': str(root / 'auth/tls/ca.crt'),
                              'target': '/usr/local/share/pas/ca.crt', 'read_only': True})
        web['environment']['PAS_CA_CERT'] = '/usr/local/share/pas/ca.crt'
    web['volumes'].append({'type': 'bind', 'source': str(root / 'lib/pas_settings.py'),
                            'target': '/usr/src/paperless/src/pas_settings.py', 'read_only': True})
    web['environment']['DJANGO_SETTINGS_MODULE'] = 'pas_settings'
    auth_env = {'AUTHENTIK_SECRET_KEY': env['PAS_AUTH_SECRET_KEY'],
                'AUTHENTIK_POSTGRESQL__HOST': 'auth-db',
                'AUTHENTIK_POSTGRESQL__NAME': 'authentik',
                'AUTHENTIK_POSTGRESQL__SSLMODE': 'disable',
                'AUTHENTIK_POSTGRESQL__USER': 'authentik',
                'AUTHENTIK_POSTGRESQL__PASSWORD': env['PAS_AUTH_DBPASS'],
                'AUTHENTIK_ERROR_REPORTING__ENABLED': 'false',
                'AUTHENTIK_DISABLE_UPDATE_CHECK': 'true'}
    services['auth-db'] = {
        'image': 'docker.io/library/postgres:' + env['PAS_V_POSTGRES'],
        'restart': 'unless-stopped', 'networks': ['identity'],
        'environment': {'POSTGRES_DB': 'authentik', 'POSTGRES_USER': 'authentik',
                        'POSTGRES_PASSWORD': env['PAS_AUTH_DBPASS']},
        'volumes': ['auth-pgdata:/var/lib/postgresql'],
        'healthcheck': {'test': ['CMD-SHELL', 'pg_isready -U authentik -d authentik'],
                        'interval': '5s', 'timeout': '5s', 'retries': 30}}
    for name, command in [('authentik', 'server'), ('auth-worker', 'worker')]:
        services[name] = {
            'image': 'ghcr.io/goauthentik/server:' + env['PAS_V_AUTHENTIK'],
            'command': command, 'restart': 'unless-stopped', 'shm_size': '512mb',
            'networks': ['identity', 'auth-edge', 'egress'],
            'environment': dict(auth_env),
            'depends_on': {'auth-db': {'condition': 'service_healthy'}},
            'volumes': ['auth-data:/data'],
            'healthcheck': {'test': ['CMD', 'ak', 'healthcheck'], 'interval': '15s',
                            'timeout': '10s', 'retries': 40, 'start_period': '60s'}}
    services['auth-worker']['user'] = 'root'
    services['auth-worker']['volumes'].append(str(root / 'auth/provision') + ':/pas:ro')
    services['auth-worker']['environment'].update({
        'AUTHENTIK_BOOTSTRAP_PASSWORD': env['PAS_AUTH_ADMIN_PASSWORD'],
        'AUTHENTIK_BOOTSTRAP_TOKEN': env['PAS_AUTH_BOOTSTRAP_TOKEN'],
        'AUTHENTIK_BOOTSTRAP_EMAIL': env['PAS_ADMIN_MAIL']})
    # No Docker socket: embedded outpost is provisioned over Authentik's API.
    dynamic = {'http': {'routers': {}, 'services': {}, 'middlewares': {
        'security': {'headers': {'contentTypeNosniff': True, 'referrerPolicy': 'same-origin',
                                'stsSeconds': 31536000 if not lan else 0}},
        'login-rate': {'rateLimit': {'average': 30, 'period': '1m', 'burst': 60}},
        'gpt-auth': {'forwardAuth': {
            'address': 'http://authentik:9000/outpost.goauthentik.io/auth/traefik',
            'trustForwardHeader': True, 'maxResponseBodySize': 4194304}},
    }}}
    commands = ['--global.sendanonymoususage=false', '--providers.file.directory=/etc/traefik/dynamic',
                '--providers.file.watch=true', '--entrypoints.websecure.address=:443',
                '--api.dashboard=false', '--log.level=WARN']
    ports = ['443:443']
    if lan:
        commands += ['--entrypoints.authsecure.address=:8443', '--entrypoints.gptsecure.address=:8444']
        ports += ['8443:8443', '8444:8444']
        certificate = {'certFile': '/tls/server.crt', 'keyFile': '/tls/server.key'}
        dynamic['tls'] = {'certificates': [certificate], 'stores': {'default': {'defaultCertificate': certificate}}}
    else:
        ports += ['80:80']
        commands += ['--entrypoints.web.address=:80',
                     '--entrypoints.web.http.redirections.entrypoint.to=websecure',
                     '--entrypoints.web.http.redirections.entrypoint.scheme=https',
                     '--certificatesresolvers.le.acme.email=' + env['PAS_LE_EMAIL'],
                     '--certificatesresolvers.le.acme.storage=/letsencrypt/acme.json',
                     '--certificatesresolvers.le.acme.httpchallenge.entrypoint=web']
        if env.get('PAS_LE_STAGING') == 'yes':
            commands += ['--certificatesresolvers.le.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory']
    for name, backend in [('docs', 'http://webserver:8000'), ('auth', 'http://authentik:9000'),
                          ('ai', 'http://paperless-gpt:8080')]:
        if name == 'ai' and 'paperless-gpt' not in services:
            continue
        entry = {'auth': 'authsecure', 'ai': 'gptsecure'}.get(name, 'websecure') if lan else 'websecure'
        router = {'rule': 'Host(`' + urlsplit(u[name]).hostname + '`)', 'entryPoints': [entry],
                  'service': name, 'tls': {} if lan else {'certResolver': 'le'},
                  'middlewares': ['security'] + (['gpt-auth'] if name == 'ai' else [])}
        dynamic['http']['routers'][name] = router
        if name == 'auth':
            login_router = copy.deepcopy(router)
            login_router.update({'rule': router['rule'] + ' && PathPrefix(`/api/v3/flows/executor/`)',
                                 'priority': 100, 'middlewares': ['security', 'login-rate']})
            dynamic['http']['routers']['auth-login'] = login_router
        dynamic['http']['services'][name] = {'loadBalancer': {'servers': [{'url': backend}]}}
        if name == 'ai':
            callback = copy.deepcopy(router)
            callback.update({'rule': router['rule'] + ' && PathPrefix(`/outpost.goauthentik.io/`)',
                             'priority': 100, 'service': 'auth', 'middlewares': ['security']})
            dynamic['http']['routers']['gpt-outpost'] = callback
    # WSGI backends read X_Forwarded_Proto as X-Forwarded-Proto; strip such aliases at ingress.
    entries = [c.split('.')[1] for c in commands if c.startswith('--entrypoints.') and '.address=' in c]
    for entry in entries:
        commands.append('--entrypoints.' + entry + '.http.aliasHeadersStrategy=delete')
    services['traefik'] = {
        'image': 'docker.io/traefik:' + env['PAS_V_TRAEFIK'],
        'restart': 'unless-stopped', 'command': commands,
        'ports': [str(ipaddress.IPv4Address(env.get('PAS_LISTEN_IP', '0.0.0.0'))) + ':' + p for p in ports],
        'networks': ['ngx-edge', 'gpt-edge', 'auth-edge', 'egress'],
        'security_opt': ['no-new-privileges:true'], 'cap_drop': ['ALL'],
        'cap_add': ['NET_BIND_SERVICE'],
        'volumes': [str(root / 'auth/dynamic') + ':/etc/traefik/dynamic:ro',
                    'letsencrypt:/letsencrypt']}
    if lan:
        services['traefik']['volumes'] += [str(root / 'auth/tls/server.crt') + ':/tls/server.crt:ro',
                                            str(root / 'auth/tls/server.key') + ':/tls/server.key:ro']
    # Resolve public VPS auth hostname internally without hairpin NAT or split DNS.
    if not lan:
        services['traefik']['networks'] = {n: {} for n in services['traefik']['networks']}
        services['traefik']['networks']['ngx-edge'] = {'aliases': [urlsplit(u['auth']).hostname]}
    # Outbound internet access must not create a shared lateral-access network.
    base['networks'].pop('egress')
    for name, service in services.items():
        networks = service['networks']
        if 'egress' in networks:
            outbound = name + '-egress'
            base['networks'][outbound] = {}
            if isinstance(networks, dict):
                networks[outbound] = networks.pop('egress')
            else:
                networks[networks.index('egress')] = outbound
    for volume in ['auth-pgdata', 'auth-data', 'letsencrypt']:
        base.setdefault('volumes', {})[volume] = {}
    return base, dynamic


def validate_public_dns(env):
    expected = env['PAS_PUBLIC_IP']
    ipaddress.IPv4Address(expected)
    for url in urls(env).values():
        hostname = urlsplit(url).hostname
        ips = {x[4][0] for x in socket.getaddrinfo(hostname, 443, socket.AF_INET)}
        if ips != {expected}:
            raise ValueError(f'DNS for {hostname} must resolve only to {expected}; got {sorted(ips)}')
        # An incorrect AAAA can make ACME fail even with the right A record.
        try:
            ipv6 = socket.getaddrinfo(hostname, 443, socket.AF_INET6)
        except socket.gaierror:
            ipv6 = []
        if ipv6:
            raise ValueError(f'Remove the AAAA record for {hostname}; this installer validates IPv4 routing only')


def main():
    root = Path.cwd()
    if sys.argv[1] == 'dns':
        validate_public_dns(os.environ)
    elif sys.argv[1] == 'render':
        base, dynamic = render(json.load(sys.stdin), os.environ, root)
        save(root / 'auth/dynamic/routes.yaml', dynamic)
        # JSON is valid YAML. Escape Compose interpolation after resolution.
        encoded = json.dumps(base).replace('$', '$$')
        # Keep runtime secrets interpolated so token creation and restore are reflected.
        for key in ['PAPERLESS_SECRET_KEY', 'PAPERLESS_DBPASS', 'PAS_ADMIN_PASSWORD',
                    'PAS_CLOUD_API_KEY', 'PAS_AUTH_SECRET_KEY', 'PAS_AUTH_DBPASS',
                    'PAS_AUTH_ADMIN_PASSWORD', 'PAS_AUTH_BOOTSTRAP_TOKEN', 'PAS_OIDC_CLIENT_SECRET']:
            value = os.environ.get(key)
            if value:
                # Replace JSON-escaped values, including inside nested OIDC JSON.
                encoded = encoded.replace(json.dumps(value)[1:-1].replace('$', '$$'), '${' + key + '}')
        token = os.environ.get('PAPERLESS_API_TOKEN') or 'pending-install'
        encoded = encoded.replace(token, '${PAPERLESS_API_TOKEN:-pending-install}')
        save(sys.argv[2], json.loads(encoded))
    elif sys.argv[1] == 'urls':
        for name, url in urls(os.environ).items():
            print(f'{name}: {url}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as exc:
        print('Authentication configuration failed: ' + str(exc), file=sys.stderr)
        sys.exit(1)
