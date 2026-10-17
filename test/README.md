# How this installer was tested — and how to reproduce it

The point of these notes is that you can re-run exactly what we ran.

## The test target

`Dockerfile.freshvm` builds a deliberately bare Ubuntu 24.04 "VM": it has systemd,
but **no Docker and no Compose**. That matters — it is what makes the installer's
"install Docker for you" path real rather than assumed.

```bash
docker build -t pas-freshvm:latest -f Dockerfile.freshvm .
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
  pas-freshvm:latest

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

Note that Paperless **soft-deletes**: `DELETE /api/documents/<id>/` only moves the
document to the trash, and the row stays in `documents_document` with a
`deleted_at`. To make a document really disappear (and make the drill mean
something) empty the trash too:

```bash
curl -fsS -X POST -H "Authorization: Token $TOKEN" -H 'Content-Type: application/json' \
  -d '{"action":"empty","documents":[1]}' http://localhost:8000/api/trash/
```

### Does a BROKEN backup get refused?
This is the important one. `psql` exits **0** when statements fail, so without
`ON_ERROR_STOP=1` a half-applied dump restores an empty database and the script
reports success. Prove the three guards, starting from a good backup `$GOOD`:

```bash
# 1. truncated dump -> refused before anything is dropped
mkdir -p /root/wk && tar xzf "$GOOD" -C /root/wk && cd /root/wk
N=$(gunzip -c db.sql.gz | wc -l)
gunzip -c db.sql.gz | head -n $((N*40/100)) | gzip > t && mv t db.sql.gz
tar czf /root/pas/backups/T1-TRUNCATED.tar.gz MANIFEST db.sql.gz media.tar.gz data.tar.gz files.tar.gz

# 2. complete dump that errors half way -> refused, previous DB rolled back
gunzip -c db.sql.gz | awk '/^CREATE TABLE public.documents_document /&&!d{
  print "INSERT INTO public.table_that_does_not_exist VALUES (1);"; d=1} {print}' | gzip > db.sql.gz

# 3. loads cleanly but the documents are missing -> caught by the MANIFEST count
gunzip -c db.sql.gz | awk '/^COPY public.documents_document /{print;s=1;next}
  s&&$0=="\\."{print;s=0;next} s{next} {print}' | gzip > db.sql.gz
```

For each one: `./install.sh restore <file> --yes` must exit **non-zero**, print
`✗ The restore FAILED: …`, and leave the document count exactly as it was.

### Is the printed basic-auth password the one that works?
Change it in `.env` and re-run — this is a path viewers take, and it used to
print credentials Traefik rejected:

```bash
docker exec pas-test sh -c 'cd /root/pas &&
  sed -i "s/^PAS_BASIC_AUTH_USER=.*/PAS_BASIC_AUTH_USER=\x27mahmoud\x27/" .env &&
  ./install.sh --yes | grep -A3 "second, separate password"'
```

The compose label must now read `basicauth.users=mahmoud:…`, the new user must get
`200` and the old one `401`. `verify()` tests this itself on every VPS install, so
the install output already tells you: *"AI screen asks for the password (401) and
the printed one works (HTTP 200)"*. To drill the failure branch, replace
`PAS_BASIC_AUTH_HASH` in `.env` with a hash of a different password while leaving
`PAS_BASIC_AUTH_FP` alone — the installer should then report that the AI screen
rejects the password it is about to print.

### Does a restore keep the password the user set themselves?

A restore must never overwrite the admin password. The backup holds the password
the user chose; `.env` holds the one the installer generated. Writing `.env`'s
password into the restored database threw the user's away and then reported the
login was fine.

```bash
# 1. the user changes their password inside Paperless, then backs up
docker compose exec -T -e P='Something-They-Chose-99' webserver \
  python3 /usr/src/paperless/src/manage.py shell -c '
import os
from django.contrib.auth import get_user_model
u = get_user_model().objects.get(username="admin")
u.set_password(os.environ["P"]); u.save()' </dev/null
./install.sh backup

# 2. restore it
./install.sh restore backups/<that file> --yes
```

Expected: exit 0, a warning that the password is now the backup's, and
`check_password` says the **backup's** password works and `.env`'s does not:

```bash
docker compose exec -T -e P='<password to test>' webserver \
  python3 /usr/src/paperless/src/manage.py shell -c '
import os
from django.contrib.auth import get_user_model
u = get_user_model().objects.get(username="admin")
print("CHECK=%s" % u.check_password(os.environ["P"]))' </dev/null
```

Then the opt-in path — `--reset-admin-password`, or `y` at the prompt — must flip
that round, and a backup whose password already matches `.env` must print
`✓ Admin 'admin' can log in with the password in .env` with **no** prompt and no
warning.

Two traps here:

- **`.env` values are single-quoted.** A harness that strips only `"` reads the
  quotes as part of the password and reports `False` for everything, including
  the cases that work. Strip both quote styles.
- **`docker compose` drains stdin even when nothing inside the container reads
  it** — and not only `exec -T`: `dc stop` and `dc up -d` do it too. That is why
  every probe above ends in `</dev/null`, and why the installer's `dc` wrapper
  adds it to every compose call (`dc_in` is the opt-out, used only for feeding a
  dump into `psql`). Without it the answer to the y/N prompt was swallowed and
  `printf 'restore\ny\n' | ./install.sh restore <file>` took the default-no
  branch every time. Note also that bash prints a `read -p` prompt **only** when
  stdin is a terminal, so a piped run answers the prompt without ever showing
  it — grep the behaviour, not the prompt text.

### Does a failed restore leak credentials to the screen?

`psql`'s `CONTEXT:` line quotes the whole row it choked on. Break a dump *inside*
the `auth_user` COPY block and that row is the admin's password hash:

```bash
mkdir -p /root/wk && tar xzf "$GOOD" -C /root/wk && cd /root/wk
gunzip -c db.sql.gz > db.sql
# drop the last tab-separated field of the first auth_user data row
python3 - db.sql <<'PY'
import sys
p=sys.argv[1]; out=[]; st=0
for ln in open(p, encoding='utf-8').read().split('\n'):
    if st==0 and ln.startswith('COPY public.auth_user '): st=1
    elif st==1 and ln=='\\.': st=2
    elif st==1 and '\t' in ln: ln=ln.rsplit('\t',1)[0]; st=2
    out.append(ln)
open(p,'w',encoding='utf-8').write('\n'.join(out))
PY
gzip -cf db.sql > db.sql.gz && rm db.sql
tar czf /root/pas/backups/N2-AUTHUSER-BROKEN.tar.gz MANIFEST db.sql.gz media.tar.gz data.tar.gz files.tar.gz
```

`./install.sh restore backups/N2-AUTHUSER-BROKEN.tar.gz --yes > out.log 2>&1` must
exit non-zero, and in `out.log`:

| check | want |
|---|---|
| the hash from the dump | 0 matches |
| `pbkdf2_…$…` anywhere | 0 matches |
| any 40-hex string (API tokens) | 0 matches |
| `CONTEXT:` lines | 0 |
| `<redacted>` | at least 1 |

and the kept `backups/failed-restore-*.log` must be mode **600** like every other
file in `backups/` — it still contains the full psql output, hash included.

### shellcheck

`shellcheck` is often not installed on the host. Run it in a container so the
check is reproducible rather than skipped:

```bash
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable -S warning install.sh
```

The only expected finding is `SC2034` on `PAS_CLOUD_BASE_URL`, which is a false
positive — it is used inside the compose heredoc.

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
