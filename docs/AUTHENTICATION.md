# Authentication and recovery

This branch adds automatic Authentik provisioning to the existing Arabic document
installer. See [validation status](IMPLEMENTATION.md) for exactly what has been tested.

## Install

Run `./install.sh` on a supported Linux machine. HomeLab is the default. Choose your
AI preferences; no Authentik client, provider, redirect URL or token needs copying.
Arabic OCR, prompt overrides, model choices and existing API integrations are retained.
Python 3 and OpenSSL are required alongside Docker Compose. Allow additional RAM for
Authentik: 6 GB total is a practical starting point without local AI; keep the existing
16 GB recommendation for local vision models.

### HomeLab

The installer detects and saves the server's IPv4 address. URLs are:

- Archive: `https://SERVER-IP`
- Authentication: `https://SERVER-IP:8443`
- AI: `https://SERVER-IP:8444`

A private CA signs an IP-address certificate. **Each client must trust
`PAPERLESS-LOCAL-CA.crt` before login.** Transfer that public certificate through a
trusted channel and import it into the operating system/browser's trusted root store.
Verify its fingerprint against `openssl x509 -in PAPERLESS-LOCAL-CA.crt -noout -fingerprint -sha256`
on the server. Never transfer `auth/tls/ca.key`. Firefox may use a separate trust store.
No external DNS provider or public domain is required. Automatic browser trust without
control of each device is not possible. Do not work around certificate warnings or
disable OIDC TLS verification.

Reserve the server IP in your router's DHCP settings. If it changes, update
`PAS_LAN_IP` in `.env` and rerun the installer; the existing CA signs a new certificate.
Rerunning renews leaf certificates with less than 30 days remaining. CA renewal and
client trust replacement require operator planning before the ten-year CA expiry.
`PAS_LISTEN_IP` can restrict the proxy to a particular host IPv4 address (default all).
A loopback-only address cannot be used as the OIDC issuer because containers have
independent loopback interfaces. Use a host LAN or bridge address reachable by the
browser and Paperless container.

### VPS

Set `PAS_TARGET=vps` when invoking the installer. It asks for the domain and a real
Let's Encrypt contact email. Create A records for `docs`, `ai-docs`, and `auth` pointing
to that server's IPv4 address. Alternate labels can be supplied through `PAS_DOCS_SUB`,
`PAS_AI_SUB`, and `PAS_AUTH_SUB`. DNS is checked before activation; conflicting AAAA
records are rejected. This initial implementation does not support CDN-proxied DNS or
IPv6-only deployment. Ports 80 and 443 must be reachable for HTTP-01 validation.

Let's Encrypt staging is for testing only. A staging certificate will intentionally
fail the trusted-TLS completion check. There is no insecure HTTP fallback.

## First login and users

Read `auth/initial-credentials.txt` privately on the server. It is mode 600 and is never
printed to CI output. Log into Authentik as `akadmin`, then use the Authentik button on
the archive login page. The installer links only that bootstrap identity, using its
immutable subject ID, to the configured Paperless administrator. Existing local
passwords remain unchanged. Initial credentials can become stale after password changes.

Open registration is disabled in Paperless. Authentik's default authentication flow
has no public enrollment link. Access groups are separate:

- `paperless-users`: allowed to authenticate to the archive.
- `paperless-ai-operators`: allowed into the shared AI application.

For additional users, create the Authentik account, assign the appropriate group,
and create the Paperless account with appropriate document permissions. The user
logs into their existing Paperless account and connects Authentik under their profile.
This explicit linking prevents duplicate accounts and unsafe email-based merging.
No new user is automatically an administrator. Authentik group membership does not
replace Paperless document permissions.

**GPT uses a shared privileged backend token.** An AI operator may act on documents
accessible through that token, regardless of their separate archive permissions.
Grant AI access only to trusted operators. ForwardAuth does not provide per-user
Paperless document authorization.

## MFA, sessions and logout

In Authentik's user settings, enroll an authenticator such as TOTP or a security key.
The default authentication flow validates enrolled factors. Keep recovery information
in a secure place. Administrators can manage users, groups and sessions in Authentik.
Sessions are limited to eight hours, and repeated login failures are checked by the
password stage, reputation policy, and proxy rate limiting. Shared-IP environments may
need rate-limit tuning. Local Paperless recovery login remains an independent login
method; Authentik MFA does not protect that local method.

Use Paperless logout to end the application session. To end SSO too, log out of
Authentik. GPT's outpost logout is at `/outpost.goauthentik.io/sign_out` on the AI URL.
These are separate sessions; this version does not claim universal single logout or
instant revocation of an already-issued outpost cookie.

## Recovery

`./install.sh auth-recover` saves a time-limited Authentik recovery link in
`auth/recovery-link.txt` (mode 600). Read it privately, use it within ten minutes,
and delete the file afterwards. No email service is needed for this operator-assisted
recovery. Self-service email recovery requires your own SMTP configuration; the
installer does not invent email credentials.

Paperless local login remains available during an Authentik outage. To reset a lost
local password, use the supported interactive command:

```bash
docker compose exec webserver python3 /usr/src/paperless/src/manage.py changepassword admin
```

Replace `admin` with your existing username. Never disable GPT's middleware to
recover access. When Authentik is unavailable, GPT must remain inaccessible.

## Updates, migration, backups and restore

The first migration takes a full safety backup before changing configuration.
Documents, database volumes, OCR, AI preferences, users and API tokens are retained.
Existing local logins are kept. Reruns reuse secrets and reconcile providers by stable
names; conflicting duplicate identities stop provisioning instead of guessing.

`./install.sh update` takes a full backup and refuses to continue if it fails. Image
versions are pinned in `.env`; changes across PostgreSQL major versions require a
separate supported database migration, not simply changing an image tag.

`./install.sh backup` briefly stops applications for a consistent snapshot, then
restarts exactly those that were running. It includes both database dumps, document
and application data, Authentik data, TLS/ACME state, OIDC secrets, `.env` and generated
configuration. Backups are mode 600 in a private directory, **not encrypted**. Store
off-host copies encrypted using your organization's backup tooling.

`./install.sh restore FILE` validates archives before changing state and takes a full
rollback backup. Authentication state and matching secrets are restored together.
If identity restore fails, applications remain stopped: restore the pre-restore full
backup instead of starting mismatched credentials. Legacy backups without Authentik
state are rejected by the authenticated restore path. Use the matching legacy
installer to restore those, then migrate. Keep the legacy installer revision with
pre-migration backups. Restore to another machine initially requires the same public
URLs/IP; change routing deliberately after identities have been restored.

`./install.sh status` checks trusted HTTPS, discovery, anonymous GPT denial, service
health and published ports without printing secrets. `./install.sh uninstall` keeps
data by default. `--purge-data` separately deletes volumes; private bind-mounted files
and `.env` must also be removed deliberately when completely decommissioning a host.

## Security model

Only Traefik publishes ports. Databases, Valkey, converters, Ollama and application
backends do not. Separate Docker networks isolate the identity database, document
database, converters, AI and proxy paths. Each service needing internet access gets
its own outbound bridge. Neither Traefik nor Authentik receives the Docker socket.
Docker administrators/root can still reach container networks and secrets: host access
is a privileged trust boundary.

Paperless uses real OIDC with PKCE, a strict callback, short-lived authorization codes,
and signed tokens. GPT's entire host route, including APIs, static files and WebSocket
handshakes, requires ForwardAuth. Only `/outpost.goauthentik.io/` routes to the identity
service without GPT authentication. The proxy rejects untrusted client forwarded
headers at ingress; it then passes its own forwarded information to Authentik.

Do not expose Docker's API or add published backend ports. Do not print `docker compose
config`, inspect environment variables, or upload raw application logs to public issues:
those administrative interfaces can contain secrets even though installer output does not.
