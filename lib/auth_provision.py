#!/usr/bin/env python3
"""Runs inside the Authentik worker. API contract: version/2026.8.5/schema.yml."""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class API:
    def __init__(self, token):
        self.token = token

    def call(self, path, data=None, method=None):
        request = urllib.request.Request('http://authentik:9000/api/v3/' + path,
                    data=None if data is None else json.dumps(data).encode(),
                    headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'},
                    method=method or ('POST' if data is not None else 'GET'))
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response) if response.status != 204 else None
        except urllib.error.HTTPError as exc:
            # API error payloads can echo client secrets. Never include them.
            raise RuntimeError(f'Authentik API {request.method} {path.split("?")[0]} returned {exc.code}') from None

    def all(self, path):
        result = []
        for page in range(1, 1000):
            data = self.call(path + f'?page_size=100&page={page}')
            result.extend(data['results'])
            if not data.get('pagination', {}).get('next'):
                return result
        raise RuntimeError('Unexpected API pagination')

    def find(self, path, field, value, required=False):
        found = [x for x in self.all(path) if x.get(field) == value]
        if len(found) > 1:
            raise RuntimeError(f'Conflicting duplicate {path} matching {field}')
        if required and not found:
            raise RuntimeError(f'Dependency not ready: {path} matching {field}')
        return found[0] if found else None

    def ensure(self, path, field, value, attrs, key='pk'):
        old = self.find(path, field, value)
        if old:
            change = {k: v for k, v in attrs.items() if old.get(k) != v}
            if change:
                return self.call(path + str(old[key]) + '/', change, 'PATCH')
            return old
        return self.call(path, attrs)


def provision(api, config):
    # Wait explicitly for the upstream default blueprints, not file ordering.
    dependencies = ['default-authentication-flow', 'default-provider-authorization-implicit-consent',
                    'default-provider-invalidation-flow']
    flows = {}
    for attempt in range(120):
        available = {x['slug']: x['pk'] for x in api.all('flows/instances/')}
        if all(k in available for k in dependencies):
            flows = available
            break
        time.sleep(5)
    if not flows:
        raise RuntimeError('Default Authentik blueprints not ready after 10 minutes')
    admin = api.find('core/users/', 'username', 'akadmin', True)
    groups = {}
    for name in ['paperless-users', 'paperless-ai-operators']:
        group = api.find('core/groups/', 'name', name)
        if group is None:
            group = api.call('core/groups/', {'name': name, 'is_superuser': False})
        if group.get('is_superuser'):
            raise RuntimeError('Application access groups must not grant Authentik superuser access')
        groups[name] = group['pk']
    # Add access only for the bootstrap administrator; preserve existing memberships.
    old_groups = set(admin['groups'])
    desired = old_groups | set(groups.values())
    if desired != old_groups:
        api.call('core/users/' + str(admin['pk']) + '/', {'groups': sorted(desired)}, 'PATCH')
    mappings = api.all('propertymappings/provider/scope/')
    scopes = []
    for scope in ['openid', 'email', 'profile']:
        managed = 'goauthentik.io/providers/oauth2/scope-' + scope
        matches = [m for m in mappings if m.get('managed') == managed]
        if len(matches) != 1:
            raise RuntimeError('Default OIDC scope mapping not ready: ' + scope)
        scopes.append(matches[0]['pk'])
    keys = api.all('crypto/certificatekeypairs/')
    signing = [k for k in keys if k.get('managed') == 'goauthentik.io/crypto/jwt-signing-key']
    if not signing:
        signing = [k for k in keys if k['name'] == 'authentik Self-signed Certificate']
    if len(signing) != 1:
        raise RuntimeError('Default signing key not ready')
    common = {'authentication_flow': flows[dependencies[0]],
              'authorization_flow': flows[dependencies[1]],
              'invalidation_flow': flows[dependencies[2]]}
    oidc = api.ensure('providers/oauth2/', 'name', 'paperless-oidc', {
        **common, 'name': 'paperless-oidc', 'client_type': 'confidential',
        # Defaults to [] (nothing allowed) when created over the API; keep it least-privilege.
        'grant_types': ['authorization_code', 'refresh_token'],
        'client_id': config['client_id'], 'client_secret': config['client_secret'],
        'redirect_uris': [{'matching_mode': 'strict', 'url': config['docs'] + '/accounts/oidc/authentik/login/callback/'}],
        'property_mappings': scopes, 'signing_key': signing[0]['pk'],
        'sub_mode': 'hashed_user_id', 'issuer_mode': 'per_provider',
        'access_code_validity': 'minutes=1', 'access_token_validity': 'minutes=5',
        'refresh_token_validity': 'hours=8', 'include_claims_in_id_token': True})
    providers = [('paperless', 'Paperless Arabic Archive', oidc, 'paperless-users', config['docs'])]
    if config['ai_enabled']:
        proxy = api.ensure('providers/proxy/', 'name', 'paperless-gpt-forwardauth', {
            **common, 'name': 'paperless-gpt-forwardauth', 'mode': 'forward_single',
            'external_host': config['ai'], 'skip_path_regex': '',
            'intercept_header_auth': False, 'basic_auth_enabled': False,
            'access_token_validity': 'minutes=5', 'refresh_token_validity': 'hours=8'})
        providers.append(('paperless-gpt', 'Paperless AI (shared access)', proxy,
                          'paperless-ai-operators', config['ai']))
    for slug, name, provider, group, launch in providers:
        app = api.ensure('core/applications/', 'slug', slug,
                         {'slug': slug, 'name': name, 'provider': provider['pk'],
                          'meta_launch_url': launch, 'policy_engine_mode': 'all'}, key='slug')
        bindings = [b for b in api.all('policies/bindings/') if b['target'] == app['pk']]
        if not any(b.get('group') == groups[group] and b.get('enabled') and not b.get('negate') for b in bindings):
            api.call('policies/bindings/', {'target': app['pk'], 'group': groups[group],
                                          'order': 0, 'enabled': True, 'failure_result': False})
    if config['ai_enabled']:
        outpost = api.find('outposts/instances/', 'managed', 'goauthentik.io/outposts/embedded', True)
        outconfig = dict(outpost['config'])
        outconfig.update({'authentik_host': config['auth'], 'authentik_host_browser': config['auth'],
                          'authentik_host_insecure': False})
        api.call('outposts/instances/' + outpost['pk'] + '/', {
            'providers': sorted(set(outpost['providers']) | {proxy['pk']}), 'config': outconfig}, 'PATCH')
    login = api.find('stages/user_login/', 'name', 'default-authentication-login', True)
    api.call('stages/user_login/' + login['pk'] + '/',
             {'session_duration': 'hours=8', 'remember_me_offset': 'seconds=0'}, 'PATCH')
    password = api.find('stages/password/', 'name', 'default-authentication-password', True)
    api.call('stages/password/' + password['pk'] + '/', {'failed_attempts_before_cancel': 5}, 'PATCH')
    # Authentik reputation tracks failures across flow restarts, unlike per-flow attempt limits.
    reputation = api.ensure('policies/reputation/', 'name', 'paperless-login-reputation', {
        'name': 'paperless-login-reputation', 'check_ip': True, 'check_username': True, 'threshold': -5})
    # The policy PASSES when score <= threshold (a bad client), so the binding must be
    # negated; un-negated it denies every login. Errors still deny (failure_result).
    wanted = {'target': flows[dependencies[0]], 'policy': reputation['pk'],
              'order': 0, 'enabled': True, 'negate': True, 'failure_result': False}
    existing = [b for b in api.all('policies/bindings/')
                if b['target'] == flows[dependencies[0]] and b.get('policy') == reputation['pk']]
    if len(existing) > 1:
        raise RuntimeError('Conflicting duplicate reputation policy bindings')
    if not existing:
        api.call('policies/bindings/', wanted)
    elif any(existing[0].get(k) != v for k, v in wanted.items()):
        # Repairs installs provisioned before this fix. Authentik's binding validator
        # dereferences `target` even on partial updates, so always send the full body.
        api.call('policies/bindings/' + str(existing[0]['pk']) + '/', wanted, 'PATCH')
    # UID is immutable, unlike username/email. Used only to link the known bootstrap account.
    return {'uid': admin['uid'], 'username': admin['username']}


if __name__ == '__main__':
    try:
        config = json.load(open('/pas/provision.json'))
        for attempt in range(120):
            try:
                result = provision(API(os.environ['AUTHENTIK_BOOTSTRAP_TOKEN']), config)
                break
            except RuntimeError as exc:
                if attempt == 119 or not str(exc).startswith(('Dependency not ready:', 'Default ')):
                    raise
                time.sleep(5)
        print(json.dumps(result))
    except Exception as exc:
        # Keep unexpected payloads/credentials out of installer logs as well.
        detail = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        print('Authentik provisioning failed: ' + detail, file=sys.stderr)
        sys.exit(1)
