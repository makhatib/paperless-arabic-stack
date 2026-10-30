#!/usr/bin/env python3
"""Browser end-to-end checks against a LIVE install. Run on the server, from the install dir:

    .venv/bin/python test/e2e_auth.py            (needs: pip install playwright; playwright install chromium)

Destructive only to disposable test users it creates (pas-e2e-*), which it deletes again.
The outage check stops Authentik briefly and starts it again. Never prints secrets.
"""
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from auth_config import urls  # noqa: E402
from playwright.sync_api import sync_playwright  # noqa: E402

RESULTS = []


def env():
    values = dict(os.environ)
    for line in Path('.env').read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            k, v = line.split('=', 1)
            values.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    return values


def credentials():
    text = Path('auth/initial-credentials.txt').read_text()
    return re.search(r'Authentik password: (.+)', text).group(1).strip()


class Authentik:
    def __init__(self, base, token, ca):
        self.base, self.token = base + '/api/v3/', token
        self.ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()

    def call(self, path, data=None, method=None):
        req = urllib.request.Request(self.base + path, method=method or ('POST' if data is not None else 'GET'),
                                     data=None if data is None else json.dumps(data).encode(),
                                     headers={'Authorization': 'Bearer ' + self.token,
                                              'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, context=self.ctx, timeout=30) as r:
            return json.load(r) if r.status != 204 else None

    def group(self, name):
        return [g for g in self.call('core/groups/?name=' + name)['results'] if g['name'] == name][0]['pk']

    def user(self, username, groups):
        password = secrets.token_urlsafe(24)
        u = self.call('core/users/', {'username': username, 'name': username, 'is_active': True,
                                      'groups': groups, 'path': 'users'})
        self.call(f'core/users/{u["pk"]}/set_password/', {'password': password})
        return u['pk'], password


def check(name, ok, detail=''):
    RESULTS.append((name, bool(ok)))
    print(('PASS' if ok else 'FAIL') + ': ' + name + ('' if ok else ' — ' + detail))


def authentik_login(page, username, password):
    """Drive Authentik's default identification + password stages (shadow DOM is pierced)."""
    try:
        page.locator('input[name="uidField"]').wait_for(timeout=60000)
    except Exception:
        page.screenshot(path='e2e-failure.png')  # local file; may show the login page, never secrets
        raise RuntimeError('Authentik login form not shown at ' + page.url.split('?')[0]) from None
    page.locator('input[name="uidField"]').fill(username)
    page.locator('input[name="uidField"]').press('Enter')
    # The password stage is a fresh render; wait for its identity header, not just any input.
    page.get_by_text('Not you?').wait_for(timeout=30000)
    pw = page.locator('input[name="password"]:visible')
    pw.wait_for(timeout=30000)
    pw.fill(password)
    if pw.input_value() != password:
        raise RuntimeError('Password field did not accept input')
    pw.press('Enter')


def fetch(page, url):
    """Same-origin fetch from the page, so the browser's own TLS trust and cookies apply."""
    return page.evaluate("""async u => { const r = await fetch(u, {credentials: 'same-origin',
        headers: {Accept: 'application/json'}}); let body = null;
        try { body = await r.json(); } catch (e) {} return {status: r.status, body}; }""", url)


def denied(page):
    try:
        page.get_by_text(re.compile('Request has been denied|Permission denied|not have access', re.I)) \
            .first.wait_for(timeout=30000)
        return True
    except Exception:
        return False


def run():
    e = env()
    u = urls(e)
    ca = 'auth/tls/ca.crt' if e['PAS_TARGET'] == 'homelab' else None
    api = Authentik(u['auth'], e['PAS_AUTH_BOOTSTRAP_TOKEN'], ca)
    ai = e.get('PAS_AI_MODE', 'none') != 'none'
    created = []
    try:
        with sync_playwright() as p:
            # The CA must already be in the NSS store (~/.local/share/pki/nssdb) — like a real client.
            browser = p.chromium.launch(args=['--no-sandbox'])

            # 1. Bootstrap admin: archive SSO, then GPT via the same SSO session, then logout.
            ctx = browser.new_context()
            page = ctx.new_page()
            page.goto(u['docs'] + '/accounts/login/')
            page.get_by_text('Authentik', exact=False).first.click()
            authentik_login(page, 'akadmin', credentials())
            try:
                page.wait_for_url(re.compile('^' + re.escape(u['docs']) + '/(dashboard|$)'), timeout=60000)
            except Exception:
                page.screenshot(path='e2e-failure.png')
                raise RuntimeError('No archive dashboard after login; stuck at ' + page.url.split('?')[0]) from None
            r = fetch(page, u['docs'] + '/api/ui_settings/')
            user = ((r['body'] or {}).get('user') or {}).get('username')
            check('archive login via OIDC as linked admin', r['status'] == 200 and user == e['PAS_ADMIN_USER'],
                  f"profile status {r['status']}")
            if ai:
                page.goto(u['ai'] + '/')
                page.wait_for_load_state('networkidle', timeout=60000)
                check('GPT reachable with SSO session', page.url.startswith(u['ai']) and 'authentik' not in page.title().lower(),
                      'landed on ' + page.url.split('?')[0])
            page.goto(u['docs'] + '/accounts/logout/')
            if page.locator('form button[type="submit"]').count():
                page.locator('form button[type="submit"]').first.click()
            page.wait_for_load_state('networkidle')
            page.goto(u['docs'] + '/accounts/login/')
            r = fetch(page, u['docs'] + '/api/profile/')
            check('archive logout ends session', r['status'] in (401, 403), f"status {r['status']}")
            ctx.close()

            # 2. User in no group: denied by Authentik for the archive application.
            pk, pw = api.user('pas-e2e-nogroup', [])
            created.append(pk)
            ctx = browser.new_context(); page = ctx.new_page()
            page.goto(u['docs'] + '/accounts/login/')
            page.get_by_text('Authentik', exact=False).first.click()
            authentik_login(page, 'pas-e2e-nogroup', pw)
            check('user without group denied archive', denied(page), 'landed on ' + page.url.split('?')[0])
            ctx.close()

            # 3. Archive-only user: denied GPT.
            if ai:
                pk, pw = api.user('pas-e2e-archive', [api.group('paperless-users')])
                created.append(pk)
                ctx = browser.new_context(); page = ctx.new_page()
                page.goto(u['ai'] + '/')
                authentik_login(page, 'pas-e2e-archive', pw)
                check('archive-only user denied GPT', denied(page), 'landed on ' + page.url.split('?')[0])
                ctx.close()

            # 4. Authentik outage: GPT fails closed, archive local login page still served.
            if ai:
                subprocess.run(['docker', 'compose', 'stop', 'authentik'], check=True, capture_output=True)
                try:
                    ctx = browser.new_context(); page = ctx.new_page()
                    try:
                        resp = page.goto(u['ai'] + '/', timeout=30000)
                        status = resp.status if resp else None
                    except Exception:
                        status = None  # connection refused/reset also counts as closed
                    check('GPT fails closed during outage', status is None or status >= 400, f'status {status}')
                    resp = page.goto(u['docs'] + '/accounts/login/')
                    check('local archive login available during outage', resp and resp.ok and
                          page.locator('input[name="password"]').count() > 0, 'login form missing')
                    ctx.close()
                finally:
                    subprocess.run(['docker', 'compose', 'start', 'authentik'], check=True, capture_output=True)
            browser.close()
    finally:
        for pk in created:
            for attempt in range(24):  # Authentik may still be restarting after the outage check
                try:
                    api.call(f'core/users/{pk}/', method='DELETE')
                    break
                except Exception:
                    time.sleep(5)
            else:
                print('WARN: could not delete test user', pk)
    failed = [n for n, ok in RESULTS if not ok]
    print(f'{len(RESULTS) - len(failed)}/{len(RESULTS)} browser checks passed')
    return not failed


if __name__ == '__main__':
    sys.exit(0 if run() else 1)
