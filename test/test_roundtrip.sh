#!/usr/bin/env bash
# LIVE install only: a document survives backup -> delete -> restore, then SSO still works.
# DESTRUCTIVE: runs a real restore. Use on a disposable host. Never echoes secrets.
# Run from the install dir: bash test/test_roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
DOCS=$(python3 lib/auth_config.py urls | sed -n 's/^docs: //p')
CA=(); [[ $PAS_TARGET == homelab ]] && CA=(--cacert auth/tls/ca.crt)
api() { curl -fsS "${CA[@]}" -H "Authorization: Token $PAPERLESS_API_TOKEN" "$@"; }
count() { api "$DOCS/api/documents/?page_size=1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])'; }
fail() { echo "FAIL: $1" >&2; exit 1; }

title="roundtrip-$(date +%s)"
doc=$(mktemp -d)/rt.txt
printf 'فاتورة رقم 1042\nInvoice 1042 round-trip test\n' > "$doc"
before=$(count)
api -F document=@"$doc" -F title="$title" "$DOCS/api/documents/post_document/" >/dev/null
for _ in $(seq 60); do (( $(count) > before )) && break; sleep 5; done
(( $(count) > before )) || fail "document was not consumed"
id=$(api "$DOCS/api/documents/?title__iexact=$title" | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["id"])')

./install.sh backup > rt-backup.log 2>&1 || fail "backup (see rt-backup.log)"
archive=$(ls -t backups/paperless-ar-backup-*.tar.gz | head -1)
api -X DELETE "$DOCS/api/documents/$id/" >/dev/null
./install.sh restore "$archive" --yes > rt-restore.log 2>&1 || fail "restore (see rt-restore.log)"

api "$DOCS/api/documents/?title__iexact=$title" | python3 -c '
import json, sys
r = json.load(sys.stdin)["results"]
sys.exit(0 if r and "فاتورة" in r[0]["content"] else 1)' || fail "document or its Arabic text missing after restore"
echo "PASS: document and Arabic OCR text survived backup -> delete -> restore"
.venv/bin/python test/e2e_auth.py
