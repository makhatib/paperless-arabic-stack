# Authentication: implementation and validation status

Branch `codex/automated-authentication`. This page records what has actually been
tested, and what has not. Read it before using this version in production.

## What changed

- Authentik `2026.8.5` (server, worker, its own PostgreSQL) is installed and
  provisioned over its API: no clicking, no copied client IDs or redirect URLs.
- Paperless-ngx signs in through OIDC (PKCE, strict callback, `authorization_code` and
  `refresh_token` grants only). The bootstrap Authentik admin is linked to the existing
  Paperless admin by immutable subject ID. Nothing is linked by email.
- Paperless-GPT sits entirely behind Traefik ForwardAuth (the embedded outpost) and fails
  closed when Authentik is down.
- Access groups: `paperless-users` (archive), `paperless-ai-operators` (GPT).
- Only Traefik publishes ports; internal networks separate data, converters, AI and identity.
  Traefik strips aliased headers (`X_Forwarded_Proto` and similar) at every entry point.
- HomeLab gets HTTPS by IP from a generated local CA; VPS gets Let's Encrypt.
- Backups include the Authentik database and volume, TLS/ACME state and secrets. Restore
  validates the archive before changing anything and takes a rollback backup first.

## Automated tests (run on every change)

| Suite | What it covers | Result |
|---|---|---|
| `python3 -m unittest discover -s test -p test_auth.py` | 21 tests: rendering in both modes, port/network isolation, closed sign-up, idempotent and resumable provisioning, duplicate/privileged-group rejection, negated reputation binding and its repair, OIDC grant types, alias-header stripping, archive traversal/symlink rules | pass |
| Provisioning payloads vs. Authentik 2026.8.5 OpenAPI schema | every create/patch body the provisioner sends | pass |
| `bash test/test_compose.sh` | real Compose parser, HomeLab and VPS × local/cloud/no AI, deterministic regeneration, CA reuse, leaf re-issue on IP change, file modes, no plaintext secrets in `compose.yaml` | pass |
| `bash test/test_prompt_install.sh` | existing Arabic prompt checks | pass |
| `bash test/test_target_questions.sh` | HomeLab/VPS question and the three subdomain questions as typed by a person (defaults, invalid and duplicate answers asked again), and unattended values from the environment | pass |
| `shellcheck -S warning` | `install.sh`, `lib/auth.sh`, `test/test_roundtrip.sh` | pass |

## Live tests (disposable Ubuntu host, Docker, HomeLab mode, cloud AI mode)

Live runs used the code in this branch at the time; later changes are covered by the
automated suites above.

The stack ran on the host's Docker bridge address so no test service was public.

| Check | Result |
|---|---|
| Fresh install, then reruns over a partial install | pass; reruns repair earlier provisioning |
| `install.sh` verification: trusted TLS, OIDC discovery, anonymous GPT denial (incl. spoofed headers, bad cookies, API/static/WebSocket paths), no backend ports published, Arabic OCR | pass |
| Browser (`test/e2e_auth.py`, Chromium trusting the local CA like a real client): | |
| — archive login via Authentik as the linked admin | pass |
| — GPT reachable with the same SSO session | pass |
| — archive logout ends the session | pass |
| — user in no group denied the archive | pass |
| — archive-only user denied GPT | pass |
| — GPT fails closed while Authentik is stopped | pass |
| — local archive login still available during that outage | pass |
| `test/test_roundtrip.sh`: Arabic document → backup → delete → restore → document and its Arabic text back, then all 7 browser checks again | pass |

## Live tests (same host, VPS mode, real domain, cloud AI mode)

Fresh install on a real public domain, with custom subdomain names for the archive,
AI and login (one A record plus two CNAMEs to it), Let's Encrypt production.

| Check | Result |
|---|---|
| DNS pre-check (CNAMEs followed, no AAAA), first-run install | pass |
| Let's Encrypt certificates for all three names; HTTP → HTTPS 301; HSTS | pass (checked from outside) |
| From the internet: anonymous and header-spoofed AI requests redirect to the login subdomain | pass |
| From the internet: only 22/80/443 open; 5432, 6379, 8000, 8080, 9000, 3000, 11434, 8443, 8444 closed | pass |
| All 7 browser checks (as above) | pass |
| Document round trip, then all 7 browser checks again | pass |
| Restore keeps ACME state: identical certificates before and after, nothing re-issued | pass |

## Bugs the live tests found (fixed, with regression tests)

1. **Every login was denied.** Authentik's reputation policy *passes* for a bad client
   (`score <= threshold`); it was bound to the login flow without `negate`. Now negated,
   and reruns repair old bindings (sending the full body, because Authentik's binding
   validator crashes on partial updates).
2. **OIDC sign-in always failed** with `invalid_request`. Providers created over the API get
   an empty grant-type list, which allows nothing.
3. **Every authenticated backup was unrestorable.** Authentik's data volume contains the
   image's own `media -> /media` symlink, and the archive check rejected all links.
   Links are now allowed only inside volume archives (which are extracted in a throwaway
   container), never written through, and still refused in host-extracted archives.
4. Earlier, Codex's live runs fixed: compressed port ranges breaking rerun detection, missing
   default certificate for IP-based HTTPS, CA-bundle permission clash between process users.

## Known limitation

The Paperless API still accepts HTTP Basic auth with a **local** Paperless username and
password (Paperless enables this unconditionally), and the local login form is kept for
recovery. Both bypass Authentik, its lockout and any MFA. Use long local passwords, and
treat them like recovery keys.

## Not yet tested — do before production

- Let's Encrypt **renewal** (issuance is tested; renewal happens ~30 days before expiry).
- **Migration from an existing legacy install** (pre-Authentik data and users). Only fresh
  installs and reruns of this version were exercised.
- **Local AI mode (Ollama) live**; only cloud mode with a dummy key ran.
- MFA enrollment and login with TOTP/WebAuthn.
- Restore onto a *different* machine.
- `auth-recover` recovery link end to end.
- Login rate limiting and reputation lockout under repeated failures.

## Running the live suites yourself

On a disposable server after `./install.sh`:

```bash
python3 -m venv .venv && .venv/bin/pip install playwright && .venv/bin/playwright install --with-deps chromium
```

HomeLab only: Chromium must trust the CA, like any client:

```bash
mkdir -p ~/.local/share/pki/nssdb && certutil -N -d sql:$HOME/.local/share/pki/nssdb --empty-password; certutil -A -d sql:$HOME/.local/share/pki/nssdb -n PaperlessCA -t C,, -i PAPERLESS-LOCAL-CA.crt
```

```bash
.venv/bin/python test/e2e_auth.py
```

`test/test_roundtrip.sh` performs a real restore: never run it on a server with data you need.
