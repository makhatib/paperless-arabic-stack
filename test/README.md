# How this installer was tested — and how to reproduce it

The point of these notes is that you can re-run exactly what we ran.

## The test target

`Dockerfile.freshvm` builds a deliberately bare Ubuntu 24.04 "VM": it has systemd,
but **no Docker and no Compose**. That matters — it is what makes the installer's
"install Docker for you" path real rather than assumed.

```bash
docker build -t nom144-freshvm:latest -f Dockerfile.freshvm .
```

## Starting a fresh target

Two volumes are needed. `/var/lib/docker` is the usual Docker-in-Docker
requirement; `/var/lib/containerd` is less obvious but just as necessary — without
it, containerd tries to mount overlayfs on top of overlayfs and image extraction
fails with `invalid argument`. That is a limitation of the test harness, not of
the installer.

```bash
docker run -d --name pas-test --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v pas-test-dockerlib:/var/lib/docker \
  -v pas-test-containerd:/var/lib/containerd \
  --tmpfs /run --tmpfs /run/lock \
  nom144-freshvm:latest

# prove it really is bare before you start
docker exec pas-test sh -c 'command -v docker || echo CONFIRMED_NO_DOCKER'
```

## Running the installer non-interactively

`--yes` takes every answer from the environment (or from an existing `.env`), which
is what makes the install scriptable and the idempotency test meaningful.

HomeLab target with cloud AI:

```bash
docker exec \
  -e PAS_TARGET=homelab -e PAS_HTTP_PORT=8000 -e PAS_GPT_LAN=no -e PAS_GPT_PORT=8080 \
  -e PAS_DOC_LANG=both -e PAS_AI_MODE=cloud -e PAS_CLOUD_PROVIDER=openrouter \
  -e PAS_CLOUD_API_KEY="$YOUR_KEY" \
  -e PAS_TZ=Asia/Riyadh -e PAS_ADMIN_USER=admin -e PAS_ADMIN_MAIL=admin@example.com \
  pas-test sh -c 'cd /root/pas && ./install.sh --yes'
```

VPS target (Let's Encrypt staging, so you do not burn the real rate limit):

```bash
docker exec \
  -e PAS_TARGET=vps -e PAS_DOMAIN=example.com \
  -e PAS_DOCS_SUB=pas-docs -e PAS_AI_SUB=pas-ai \
  -e PAS_LE_EMAIL=you@a-real-domain.com -e PAS_LE_STAGING=yes \
  -e PAS_BASIC_AUTH_USER=admin \
  -e PAS_DOC_LANG=arabic -e PAS_AI_MODE=cloud -e PAS_CLOUD_PROVIDER=openrouter \
  -e PAS_CLOUD_API_KEY=sk-dummy-is-fine-for-a-routing-test \
  -e PAS_TZ=Asia/Riyadh -e PAS_ADMIN_USER=admin -e PAS_ADMIN_MAIL=admin@example.com \
  pas-test sh -c 'cd /root/pas && ./install.sh --yes'
```

Note `PAS_LE_EMAIL` must use a **real public** domain. Let's Encrypt rejects
reserved endings like `.example` or `.local`, and the installer now refuses them
up front rather than letting you discover it later in the Traefik log.

## Checks worth re-running

### Did Arabic OCR actually get installed?
This is the one that used to fail silently. The container logs one line and starts
anyway, so assert it:

```bash
docker exec pas-test sh -c 'cd /root/pas && docker compose exec -T webserver tesseract --list-langs'
```

### Is the basic-auth hash intact end to end?
The hash contains `$`, which gets eaten at several points if anything is quoted
wrongly. Check what the live container actually received:

```bash
docker exec pas-test sh -c \
  'docker inspect paperless-ar-paperless-gpt-1 --format "{{index .Config.Labels \"traefik.http.middlewares.gpt-auth.basicauth.users\"}}"'
```

Then test it for real. Build the header yourself — `curl -u` through nested
`sh -c` quoting is how we got a false failure the first time:

```bash
docker exec pas-test sh -c '
  AUTH=$(printf "admin:THE_PASSWORD" | base64 -w0)
  curl -sk -o /dev/null -w "with creds: %{http_code}\n" \
    -H "Authorization: Basic $AUTH" \
    --resolve pas-ai.example.com:443:127.0.0.1 https://pas-ai.example.com/'
```

Expected: `401` with no credentials, `401` with wrong ones, `200` with the right ones.

### Does the HTTPS redirect swallow the ACME challenge?
If this returns `301` instead of `404`, Let's Encrypt can never succeed:

```bash
docker exec pas-test curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Host: pas-docs.example.com' \
  http://127.0.0.1/.well-known/acme-challenge/probe
```

### Is the re-run really idempotent?
Run the same command twice more and compare. The last two runs must produce a
byte-identical `compose.yaml`, and the admin password, API token and documents
must not change:

```bash
docker exec pas-test sh -c 'cd /root/pas && sha256sum compose.yaml'
```

### Restore drill
Take a backup, delete a document through the API, restore, and confirm the
document comes back **with its AI-corrected text** and that the original file is
still downloadable. A backup nobody has restored is not a backup.

## What cannot be tested this way

Issuing a real Let's Encrypt certificate, because the target cannot receive an
inbound connection on port 80 from the internet. Everything short of that is
verifiable: account registration, the certificate request, the published challenge
token, and the redirect check above.

The container also sees the host's `/proc/meminfo`, so the low-RAM warning does
not trigger here. On a real VPS it reads correctly.

## Cleaning up

```bash
docker rm -f pas-test
docker volume rm -f pas-test-dockerlib pas-test-containerd
```
