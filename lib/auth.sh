# shellcheck shell=bash
# Authentication lifecycle, sourced by install.sh. Never enable shell tracing.
auth_prepare() {
    step_header "Preparing secure authentication"
    command_exists python3 || die "Python 3 is required: apt-get install python3"
    command_exists openssl || die "OpenSSL is required: apt-get install openssl"
    local k
    for k in PAS_AUTH_SECRET_KEY PAS_AUTH_DBPASS PAS_AUTH_ADMIN_PASSWORD PAS_AUTH_BOOTSTRAP_TOKEN PAS_OIDC_CLIENT_SECRET; do
        [[ -n ${!k:-} ]] || printf -v "$k" '%s' "$(generate_secret 48)"
        env_set "$k" "${!k}"
    done
    env_set PAS_OIDC_CLIENT_ID "${PAS_OIDC_CLIENT_ID:-paperless-arabic}"
    env_set PAS_V_AUTHENTIK "${PAS_V_AUTHENTIK:-2026.8.5}"
    env_set PAS_AUTH_SUB "${PAS_AUTH_SUB:-auth}"
    env_set PAS_AUTH_ENABLED yes
    env_set PAS_LISTEN_IP "${PAS_LISTEN_IP:-0.0.0.0}"
    if [[ $PAS_TARGET == homelab ]]; then
        env_set PAS_LAN_IP "${PAS_LAN_IP:-$(lan_ip)}"
    fi
    load_env
    mkdir -p auth/tls auth/dynamic auth/provision
    chmod 700 auth auth/tls auth/dynamic auth/provision
    if [[ $PAS_TARGET == vps ]]; then
        PAS_PUBLIC_IP=${PAS_PUBLIC_IP:-$(curl -fsS --max-time 10 https://api.ipify.org)}
        export PAS_PUBLIC_IP
        python3 lib/auth_config.py dns || die "Fix the docs, AI and auth A records before retrying. No HTTP fallback is allowed."
    else
        python3 -c 'import ipaddress,os; ipaddress.IPv4Address(os.environ["PAS_LAN_IP"])' \
            || die "Could not detect a LAN IPv4 address. Set PAS_LAN_IP to this server's address."
        if [[ ! -f auth/tls/ca.key ]]; then
            [[ ! -f auth/tls/ca.crt ]] || die "CA key missing. Restore auth/tls from backup; refusing to rotate client trust silently."
            openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
                -keyout auth/tls/ca.key -out auth/tls/ca.crt -subj '/CN=Paperless Arabic Local CA' \
                -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
        fi
        if [[ ! -f auth/tls/server.crt ]] || ! openssl x509 -in auth/tls/server.crt -checkend 2592000 -noout >/dev/null \
            || ! openssl verify -CAfile auth/tls/ca.crt -verify_ip "$PAS_LAN_IP" auth/tls/server.crt >/dev/null 2>&1; then
            openssl req -new -newkey rsa:3072 -nodes -keyout auth/tls/server.key \
                -out auth/tls/server.csr -subj '/CN=Paperless Arabic Stack' >/dev/null 2>&1
            printf 'subjectAltName=IP:%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' \
                "$PAS_LAN_IP" > auth/tls/server.ext
            openssl x509 -req -in auth/tls/server.csr -CA auth/tls/ca.crt -CAkey auth/tls/ca.key \
                -CAcreateserial -out auth/tls/server.crt -days 365 -sha256 -extfile auth/tls/server.ext >/dev/null 2>&1
        fi
        chmod 600 auth/tls/*
        # Public certificate only. Copy this to client trust stores, never ca.key.
        cp auth/tls/ca.crt PAPERLESS-LOCAL-CA.crt
        chmod 644 PAPERLESS-LOCAL-CA.crt auth/tls/ca.crt
    fi
    python3 - <<'PY'
import os
from pathlib import Path
from lib.auth_config import urls, save
u = urls(os.environ)
save('auth/provision/provision.json', {**u, 'client_id': os.environ['PAS_OIDC_CLIENT_ID'],
     'client_secret': os.environ['PAS_OIDC_CLIENT_SECRET'], 'ai_enabled': os.environ['PAS_AI_MODE'] != 'none'})
p = Path('auth/initial-credentials.txt')
if not p.exists():
    p.write_text('Initial credentials; passwords may have changed since installation.\n'
        + 'Authentik username: akadmin\nAuthentik password: ' + os.environ['PAS_AUTH_ADMIN_PASSWORD']
        + '\nPaperless local recovery username: ' + os.environ['PAS_ADMIN_USER']
        + '\nPaperless initial local password: ' + os.environ['PAS_ADMIN_PASSWORD'] + '\n')
    p.chmod(0o600)
PY
    for k in 443 8443 8444; do
        [[ $PAS_TARGET == vps && $k != 443 ]] && continue
        if port_in_use "$k" && ! port_owned_by_us "$k"; then
            die "Port $k is busy. Stop the conflicting service and retry."
        fi
    done
}

auth_render() {
    local input=$1 output=$2
    # Resolve the existing generator with Compose itself; no host YAML package.
    dc -f "$input" config --format json 2>auth/compose-validation.log \
        | python3 lib/auth_config.py render "$output" \
        || die "Could not build secure Compose configuration. See private auth/compose-validation.log."
    dc -f "$output" config --quiet 2>auth/compose-validation.log \
        || die "Secure Compose validation failed. The previous compose.yaml remains unchanged."
}

auth_start() {
    step_header "Starting Authentik"
    dc up -d auth-db authentik auth-worker traefik
    local attempt
    for attempt in $(seq 1 180); do
        if dc exec -T authentik ak healthcheck >/dev/null 2>&1 && \
           dc exec -T auth-worker ak healthcheck >/dev/null 2>&1; then
            return 0
        fi
        (( attempt % 12 )) || print_info "Authentik is still applying initial database migrations..."
        sleep 5
    done
    die "Authentik did not become healthy. Re-run after checking docker compose logs authentik auth-worker."
}

auth_provision() {
    step_header "Provisioning SSO and application access"
    dc_in exec -T auth-worker python < lib/auth_provision.py > auth/admin-identity.json \
        || die "Authentik provisioning failed. GPT stays protected; re-run to resume."
    python3 - <<'PY'
import json,os
from lib.auth_config import save
identity = json.load(open('auth/admin-identity.json'))
save('auth/link-admin.json', {'uid': identity['uid'], 'paperless_username': os.environ['PAS_ADMIN_USER']})
PY
}

auth_link_admin() {
    dc_in exec -T webserver python3 /usr/src/paperless/src/manage.py shell \
        -c "$(cat lib/link_admin.py)" < auth/link-admin.json > auth/link-result.log 2>&1 \
        || die "Could not link the bootstrap administrator. Existing local login is retained. See private auth/link-result.log."
    grep -q PAS_ADMIN_LINK_OK auth/link-result.log || die "Bootstrap identity linking was not confirmed."
}

auth_verify() {
    step_header "Checking HTTPS and authentication boundaries"
    python3 lib/auth_verify.py || die "Authentication verification failed. Installation is NOT complete; run ./install.sh status after fixing the reported problem."
    env_set PAS_AUTH_VERIFIED yes
    print_success "HTTPS, OIDC discovery, anonymous GPT denial and port isolation checks passed"
}

auth_summary() {
    print_header "PAPERLESS ARABIC STACK — INSTALLATION COMPLETE"
    python3 lib/auth_config.py urls
    echo "Authentication: Authentik (username: akadmin)"
    echo "Initial credentials: auth/initial-credentials.txt (mode 600; never printed to logs)"
    echo "Local recovery login: retained; use your existing Paperless password after migration."
    echo "Security checks: HTTPS, OIDC discovery, GPT anonymous denial, port isolation passed."
    echo "Browser login/session tests: run the documented E2E suite; not inferred from health checks."
    [[ $PAS_TARGET != homelab ]] || echo "Client action: trust PAPERLESS-LOCAL-CA.crt on each device before signing in."
    echo "Arabic OCR and AI settings are preserved. Drop documents into ./consume."
    python3 lib/auth_config.py urls > INSTALLATION_INFO.txt
}

auth_backup() {
    local work=$1
    [[ ${PAS_AUTH_ENABLED:-no} == yes ]] || return 0
    dc exec -T auth-db pg_dump -U authentik -d authentik -Fc > "$work/authentik.dump" \
        || die "Authentik backup failed; refusing an incomplete backup."
    dc_in exec -T auth-db pg_restore --list < "$work/authentik.dump" >/dev/null \
        || die "Authentik dump validation failed."
    docker run --rm -v "${COMPOSE_PROJECT}_auth-data:/src:ro" -v "$work:/dst" \
        docker.io/library/alpine:3.23.3 tar czf /dst/auth-data.tar.gz -C /src .
    docker run --rm -v "${COMPOSE_PROJECT}_letsencrypt:/src:ro" -v "$work:/dst" \
        docker.io/library/alpine:3.23.3 tar czf /dst/letsencrypt.tar.gz -C /src .
}

# Called BEFORE Paperless restore mutates anything. A full rollback snapshot is mandatory.
auth_restore_preflight() {
    local work=$1
    [[ ${PAS_AUTH_ENABLED:-no} == yes ]] || return 0
    [[ -s $work/authentik.dump && -s $work/auth-data.tar.gz && -s $work/letsencrypt.tar.gz ]] \
        || die "This backup lacks authentication state. Restore legacy backups with the matching legacy installer, then migrate. Nothing has been changed."
    dc_in exec -T auth-db pg_restore --list < "$work/authentik.dump" >/dev/null \
        || die "Invalid Authentik dump. Nothing has been changed."
    local listing; listing=$(tar tzf "$work/files.tar.gz")
    grep -qx 'auth/provision/provision.json' <<<"$listing" \
        || die "Backup is missing authentication configuration. Nothing has been changed."
    print_info "Taking a complete rollback backup before restoring identities and documents."
    cmd_backup
    dc stop authentik auth-worker paperless-gpt webserver
}

auth_restore() {
    local work=$1
    [[ ${PAS_AUTH_ENABLED:-no} == yes ]] || return 0
    # Restore configuration together with identities, never retain unrelated OIDC keys.
    tar xzf "$work/files.tar.gz" -C "$SCRIPT_DIR" .env compose.yaml auth
    chmod 600 "$ENV_FILE" "$COMPOSE_FILE"
    load_env
    # Logical dumps omit role passwords. Align both existing cluster roles with restored secrets.
    python3 -c 'import os; print("ALTER ROLE authentik PASSWORD " + chr(39) + os.environ["PAS_AUTH_DBPASS"].replace(chr(39), chr(39)*2) + chr(39) + ";")' \
        | dc_in exec -T auth-db psql -v ON_ERROR_STOP=1 -U authentik -d authentik >/dev/null
    python3 -c 'import os; print("ALTER ROLE paperless PASSWORD " + chr(39) + os.environ["PAPERLESS_DBPASS"].replace(chr(39), chr(39)*2) + chr(39) + ";")' \
        | dc_in exec -T db psql -v ON_ERROR_STOP=1 -U paperless -d paperless >/dev/null
    dc_in exec -T auth-db pg_restore --clean --if-exists --exit-on-error --no-owner \
        -U authentik -d authentik < "$work/authentik.dump" >auth/restore.log 2>&1 \
        || die "Identity restore failed. Applications remain stopped. Restore the complete pre-restore backup; details in private auth/restore.log."
    local v
    for v in auth-data letsencrypt; do
        docker run --rm -v "${COMPOSE_PROJECT}_${v}:/dst" -v "$work:/src:ro" \
            docker.io/library/alpine:3.23.3 sh -c "find /dst -mindepth 1 -maxdepth 1 -exec rm -rf {} +; tar xzf /src/${v}.tar.gz -C /dst"
    done
}

auth_quiesce() {
    # Consistent document/GPT/identity snapshot; restart exactly those previously running.
    PAS_BACKUP_RESUME=()
    local service running
    running=$(dc ps --status running --services)
    for service in webserver paperless-gpt authentik auth-worker; do
        contains_line "$running" "$service" && PAS_BACKUP_RESUME+=("$service")
    done
    if (( ${#PAS_BACKUP_RESUME[@]} )); then
        dc stop "${PAS_BACKUP_RESUME[@]}"
        trap 'auth_resume' EXIT
    fi
}

auth_resume() {
    if (( ${#PAS_BACKUP_RESUME[@]} )); then
        dc start "${PAS_BACKUP_RESUME[@]}" >/dev/null
        PAS_BACKUP_RESUME=()
        trap - EXIT
    fi
}
PAS_BACKUP_RESUME=()

auth_recover() {
    mkdir -p auth
    chmod 700 auth
    dc exec -T authentik ak create_recovery_key 10 akadmin > auth/recovery-link.txt 2>auth/recovery-error.log \
        || die "Recovery link generation failed. See private auth/recovery-error.log."
    chmod 600 auth/recovery-link.txt
    print_success "A 10-minute recovery link is in auth/recovery-link.txt. Read it privately and delete the file after use."
}
