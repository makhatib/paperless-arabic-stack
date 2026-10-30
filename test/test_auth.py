#!/usr/bin/env python3
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
from auth_config import render, urls, validate_public_dns
from auth_provision import API, provision
from backup_check import unpack


def environment(target='homelab'):
    return dict(PAS_TARGET=target, PAS_LAN_IP='192.168.1.20', PAS_DOMAIN='example.com',
        PAS_DOCS_SUB='docs', PAS_AI_SUB='ai-docs', PAS_AUTH_SUB='auth', PAS_LE_EMAIL='operator@example.com',
        PAS_OIDC_CLIENT_ID='test-client', PAS_OIDC_CLIENT_SECRET='test-secret',
        PAS_AUTH_SECRET_KEY='test-key', PAS_AUTH_DBPASS='test-db', PAS_V_POSTGRES='18.6',
        PAS_AUTH_ADMIN_PASSWORD='test-password', PAS_AUTH_BOOTSTRAP_TOKEN='test-token',
        PAS_ADMIN_MAIL='admin@example.com', PAS_V_AUTHENTIK='2026.8.5', PAS_V_TRAEFIK='v3.7.16')


def base():
    services = {name: {'image': 'test:1', 'networks': ['internal'], 'ports': ['123:456'], 'labels': {'old': 'value'}}
        for name in ['webserver', 'db', 'broker', 'gotenberg', 'tika', 'paperless-gpt', 'ollama']}
    services['webserver'].update(environment={'PAPERLESS_OCR_LANGUAGE': 'ara+eng'}, volumes=['media:/usr/src/paperless/media'])
    services['paperless-gpt']['environment'] = {'VISION_LLM_MODEL': 'qwen2.5vl:7b', 'PAPERLESS_API_TOKEN': 'preserved'}
    return {'services': services, 'volumes': {'media': {'name': 'paperless-ar_media'}}}


class ConfigTest(unittest.TestCase):
    def test_both_modes_isolate_backends_and_preserve_processing(self):
        for target in ['homelab', 'vps']:
            with self.subTest(target=target):
                c, routes = render(base(), environment(target), ROOT)
                self.assertEqual(c['services']['webserver']['environment']['PAPERLESS_OCR_LANGUAGE'], 'ara+eng')
                self.assertEqual(c['services']['paperless-gpt']['environment']['PAPERLESS_API_TOKEN'], 'preserved')
                self.assertEqual(c['volumes']['media']['name'], 'paperless-ar_media')
                for name, service in c['services'].items():
                    if name != 'traefik': self.assertNotIn('ports', service)
                    self.assertNotIn('docker.sock', json.dumps(service))
                self.assertEqual(routes['http']['routers']['ai']['middlewares'], ['security', 'gpt-auth'])
                self.assertEqual(routes['http']['routers']['gpt-outpost']['service'], 'auth')
                self.assertIn('PathPrefix(`/outpost.goauthentik.io/`)', routes['http']['routers']['gpt-outpost']['rule'])
                self.assertFalse(set(c['services']['paperless-gpt']['networks']) & set(c['services']['auth-db']['networks']))
                self.assertFalse(set(c['services']['ollama']['networks']) & set(c['services']['authentik']['networks']))
                self.assertNotIn('ca.key', json.dumps(c['services']['traefik']))

    def test_ip_https_has_explicit_default_certificate(self):
        _, r = render(base(), environment(), ROOT)
        self.assertEqual(r['tls']['stores']['default']['defaultCertificate']['certFile'], '/tls/server.crt')
        self.assertNotIn('login-rate', r['http']['routers']['auth']['middlewares'])
        self.assertIn('/api/v3/flows/executor/', r['http']['routers']['auth-login']['rule'])

    def test_every_entrypoint_strips_alias_headers(self):
        for target, expected in [('homelab', {'websecure', 'authsecure', 'gptsecure'}),
                                 ('vps', {'web', 'websecure'})]:
            c, _ = render(base(), environment(target), ROOT)
            cmd = c['services']['traefik']['command']
            got = {x.split('.')[1] for x in cmd if x.endswith('.http.aliasHeadersStrategy=delete')}
            self.assertEqual(got, expected)

    def test_closed_registration_and_no_implicit_admin(self):
        c, _ = render(base(), environment(), ROOT)
        e = c['services']['webserver']['environment']
        self.assertEqual(e['PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS'], 'false')
        self.assertEqual(e['PAPERLESS_DISABLE_REGULAR_LOGIN'], 'false')
        self.assertNotIn('PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP', e)
        self.assertEqual(e['PAPERLESS_ENABLE_HTTP_REMOTE_USER'], 'false')

    def test_no_ai_has_no_gpt_route(self):
        b = base(); del b['services']['paperless-gpt']
        c, r = render(b, environment(), ROOT)
        self.assertNotIn('ai', r['http']['routers'])
        self.assertNotIn('gpt-outpost', r['http']['routers'])

    def test_repeat_is_identical_and_input_not_mutated(self):
        b = base(); before = copy.deepcopy(b)
        self.assertEqual(render(b, environment(), ROOT), render(b, environment(), ROOT))
        self.assertEqual(b, before)

    def test_missing_oidc_secret_fails(self):
        e = environment(); del e['PAS_OIDC_CLIENT_SECRET']
        with self.assertRaises(KeyError): render(base(), e, ROOT)

    def test_invalid_lan_address_fails(self):
        e = environment(); e['PAS_LAN_IP'] = '127.0.0.1/evil'
        with self.assertRaises(ValueError): urls(e)

    def test_wrong_dns_rejected(self):
        e = environment('vps'); e['PAS_PUBLIC_IP'] = '192.0.2.1'
        with patch('auth_config.socket.getaddrinfo', return_value=[(None,None,None,None,('192.0.2.2',443))]):
            with self.assertRaises(ValueError): validate_public_dns(e)


class MemoryAPI(API):
    def __init__(self):
        self.objects = {
            'flows/instances/': [{'slug': s, 'pk': s} for s in ['default-authentication-flow',
                'default-provider-authorization-implicit-consent', 'default-provider-invalidation-flow']],
            'core/users/': [{'username': 'akadmin', 'pk': 1, 'uid': 'immutable-sub', 'groups': ['existing-group']}],
            'propertymappings/provider/scope/': [{'pk': s, 'managed': 'goauthentik.io/providers/oauth2/scope-' + s} for s in ['openid','email','profile']],
            'crypto/certificatekeypairs/': [{'pk': 'signing', 'name': 'authentik Self-signed Certificate'}],
            'outposts/instances/': [{'pk': 'outpost', 'managed': 'goauthentik.io/outposts/embedded', 'config': {}, 'providers': []}],
            'stages/user_login/': [{'pk': 'login', 'name': 'default-authentication-login'}],
            'stages/password/': [{'pk': 'password', 'name': 'default-authentication-password'}]}
        self.calls = []
    def all(self, path): return copy.deepcopy(self.objects.get(path, []))
    def call(self, path, data=None, method=None):
        self.calls.append((path, copy.deepcopy(data), method))
        if method == 'PATCH':
            prefix, key = path.rstrip('/').rsplit('/', 1); prefix += '/'
            for item in self.objects[prefix]:
                if str(item.get('pk')) == key or item.get('slug') == key:
                    item.update(data); return copy.deepcopy(item)
            raise RuntimeError('Not found')
        pk = len(self.calls) + 100
        item = {'pk': pk if path.startswith('providers/') else str(pk), **data}
        self.objects.setdefault(path, []).append(item)
        return copy.deepcopy(item)


class ProvisionTest(unittest.TestCase):
    def config(self):
        return {**urls(environment()), 'client_id':'id', 'client_secret':'secret', 'ai_enabled':True}
    def test_idempotent_and_keeps_memberships(self):
        a = MemoryAPI(); first = provision(a, self.config())
        count = {k:len(v) for k,v in a.objects.items()}
        self.assertEqual(first, provision(a, self.config()))
        self.assertEqual(count, {k:len(v) for k,v in a.objects.items()})
        self.assertIn('existing-group', a.objects['core/users/'][0]['groups'])
        self.assertEqual(first['uid'], 'immutable-sub')
        self.assertEqual(len(a.objects['policies/bindings/']), 3)
        self.assertTrue(all(not b['failure_result'] for b in a.objects['policies/bindings/']))
        rep = [b for b in a.objects['policies/bindings/'] if b.get('policy')]
        self.assertEqual(len(rep), 1)
        self.assertTrue(rep[0]['negate'], 'reputation passes for BAD clients; must be negated')
    def test_oidc_allows_only_code_and_refresh_grants(self):
        a = MemoryAPI(); provision(a, self.config())
        self.assertEqual(a.objects['providers/oauth2/'][0]['grant_types'], ['authorization_code', 'refresh_token'])
    def test_repairs_unnegated_reputation_binding(self):
        a = MemoryAPI(); provision(a, self.config())
        rep = [b for b in a.objects['policies/bindings/'] if b.get('policy')][0]
        rep['negate'] = False
        provision(a, self.config())
        self.assertTrue(rep['negate'])
        self.assertEqual(len([b for b in a.objects['policies/bindings/'] if b.get('policy')]), 1)
    def test_recover_after_interruption(self):
        a = MemoryAPI(); real = a.call
        def fail(path, data=None, method=None):
            if path == 'core/applications/': raise RuntimeError('interrupted')
            return real(path,data,method)
        a.call = fail
        with self.assertRaises(RuntimeError): provision(a,self.config())
        a.call = real
        provision(a,self.config())
        self.assertEqual(len(a.objects['providers/oauth2/']),1)
    def test_reject_privileged_access_group(self):
        a = MemoryAPI(); a.objects['core/groups/'] = [{'pk': 'bad', 'name':'paperless-users','is_superuser':True}]
        with self.assertRaises(RuntimeError): provision(a,self.config())
    def test_missing_signing_key_fails(self):
        a = MemoryAPI(); a.objects['crypto/certificatekeypairs/'] = []
        with self.assertRaises(RuntimeError): provision(a,self.config())
    def test_duplicate_provider_fails(self):
        a = MemoryAPI(); a.objects['providers/oauth2/'] = [{'name':'paperless-oidc'}]*2
        with self.assertRaises(RuntimeError): provision(a,self.config())


class ArchiveTest(unittest.TestCase):
    def test_traversal_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/'bad.tar.gz'
            with tarfile.open(f,'w:gz') as t:
                m=tarfile.TarInfo('../escape'); m.size=1; t.addfile(m,io.BytesIO(b'x'))
            with self.assertRaises(ValueError): unpack(f,Path(d)/'out')
            self.assertFalse((Path(d)/'out').exists())
    def backup(self, d, nested_name, nested_members):
        inner = io.BytesIO()
        with tarfile.open(fileobj=inner, mode='w:gz') as t:
            for m in nested_members:
                t.addfile(m, io.BytesIO(b'x') if m.isfile() else None)
        f = Path(d) / 'b.tar.gz'
        with tarfile.open(f, 'w:gz') as t:
            for name in ['db.sql.gz', 'media.tar.gz', 'data.tar.gz', 'files.tar.gz', 'MANIFEST', nested_name]:
                data = inner.getvalue() if name == nested_name else b''
                if name.endswith('.tar.gz') and name != nested_name:
                    empty = io.BytesIO()
                    with tarfile.open(fileobj=empty, mode='w:gz'): pass
                    data = empty.getvalue()
                m = tarfile.TarInfo('./' + name); m.size = len(data); t.addfile(m, io.BytesIO(data))
        return f
    def link(self, name, target):
        m = tarfile.TarInfo(name); m.type = tarfile.SYMTYPE; m.linkname = target; return m
    def regular(self, name):
        m = tarfile.TarInfo(name); m.size = 1; return m
    def test_volume_symlink_round_trips(self):
        with tempfile.TemporaryDirectory() as d:
            unpack(self.backup(d, 'auth-data.tar.gz', [self.link('./media', '/media')]), Path(d) / 'out')
    def test_write_through_volume_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            f = self.backup(d, 'auth-data.tar.gz', [self.link('./media', '/etc'), self.regular('./media/passwd')])
            with self.assertRaises(ValueError): unpack(f, Path(d) / 'out')
    def test_symlink_in_host_extracted_archive_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            f = self.backup(d, 'files.tar.gz', [self.link('./auth', '/etc')])
            with self.assertRaises(ValueError): unpack(f, Path(d) / 'out')
    def test_incomplete_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/'bad.tar.gz'
            with tarfile.open(f,'w:gz'): pass
            with self.assertRaises(ValueError): unpack(f,Path(d)/'out')


if __name__ == '__main__': unittest.main()
