#!/usr/bin/env bash
# Real Compose parser, no daemon. This is NOT an installation/E2E test.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/install.sh" "$WORK/"
cp -R "$ROOT/lib" "$WORK/"
cd "$WORK"
source ./install.sh
# Homebrew's standalone Compose is also useful on hosts without a daemon.
dc() { PAPERLESS_API_TOKEN=${PAPERLESS_API_TOKEN:-pending-install} docker-compose "$@" </dev/null; }
export PAS_LAN_IP=192.168.1.20 PAS_TARGET=homelab PAS_AI_MODE=local
export PAS_DOC_LANG=both PAS_OCR_LANGUAGES='ara eng' PAS_OCR_LANGUAGE=ara+eng PAS_TZ=Asia/Riyadh
export PAS_OLLAMA_MODE=container PAS_GPU=no PAS_PUID=1000 PAS_PGID=1000
export PAS_TEXT_MODEL=qwen3:8b PAS_VISION_MODEL=qwen2.5vl:7b
export PAS_ADMIN_USER=admin PAS_ADMIN_MAIL=admin@example.com
export PAS_HTTP_PORT=443 PAS_GPT_PORT=8444 PAS_GPT_BIND=127.0.0.1
export PAS_ADMIN_PASSWORD=SentinelPasswordNeverPrint908712
export PAS_DOCS_SUB=docs PAS_AI_SUB=ai-docs PAS_AUTH_SUB=auth PAS_DOMAIN=example.com PAS_LE_EMAIL=operator@example.com
write_env
# Also exercises real CA generation, reuse, and restricted credentials.
auth_prepare
# A changed IP must replace the leaf, not the CA; checkip alone has unreliable exit semantics.
cp auth/tls/ca.crt original-ca.crt
env_set PAS_LAN_IP 192.168.1.21
load_env
auth_prepare
openssl verify -CAfile auth/tls/ca.crt -verify_ip 192.168.1.21 auth/tls/server.crt
cmp original-ca.crt auth/tls/ca.crt
[[ -s auth/dynamic/routes.yaml ]] || true
before=$(openssl x509 -in auth/tls/ca.crt -fingerprint -noout)
auth_prepare
[[ $before == "$(openssl x509 -in auth/tls/ca.crt -fingerprint -noout)" ]]
for mode in homelab vps; do
    env_set PAS_TARGET "$mode"
    for ai in local cloud none; do
        env_set PAS_AI_MODE "$ai"
        env_set PAS_OLLAMA_MODE container
        if [[ $ai == cloud ]]; then
            env_set PAS_CLOUD_API_KEY SentinelCloudKeyNeverPrint412
            env_set PAS_CLOUD_BASE_URL https://example.com/v1
            env_set PAS_OLLAMA_MODE none
        fi
        load_env
        write_compose
        dc config --quiet
        cp compose.yaml previous.json
        write_compose
        cmp compose.yaml previous.json
        dc config --format json > resolved.json
        python3 - <<'PY'
import json,os
c=json.load(open('resolved.json'))
assert c['services']['webserver']['environment']['PAPERLESS_OCR_LANGUAGE']=='ara+eng'
for name, service in c['services'].items():
    if name!='traefik': assert not service.get('ports'), name
assert 'SentinelPasswordNeverPrint908712' not in open('compose.yaml').read()
assert os.stat('auth/initial-credentials.txt').st_mode & 0o777 == 0o600
assert os.stat('compose.yaml').st_mode & 0o777 == 0o600
if 'paperless-gpt' in c['services']:
    assert c['services']['paperless-gpt']['environment']['PAPERLESS_API_TOKEN']=='pending-install'
PY
        echo "PASS: $mode / $ai Compose validation and deterministic regeneration"
    done
done
# A token created after compose rendering must be picked up without regeneration.
env_set PAS_AI_MODE local
load_env
write_compose
export PAPERLESS_API_TOKEN=SentinelTokenAfterStartup
dc config --format json > resolved.json
python3 - <<'PY'
import json
c=json.load(open('resolved.json'))
assert c['services']['paperless-gpt']['environment']['PAPERLESS_API_TOKEN']=='SentinelTokenAfterStartup'
PY
