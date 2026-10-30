#!/usr/bin/env bash
# The install location and VPS subdomains are asked, not silently defaulted.
# Feeds answers on stdin the way a person types them. No Docker needed.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fails=0

run() {  # run "env assignments" "stdin" -> prints chosen values, or DIED
    local env=$1 input=$2
    (
        # shellcheck disable=SC1091
        source "$ROOT/install.sh"
        trap - ERR
        port_in_use() { return 1; }
        NONINTERACTIVE=0
        eval "$env"
        ask_target >/dev/null 2>&1
        echo "$PAS_TARGET ${PAS_DOMAIN:-} ${PAS_DOCS_SUB:-} ${PAS_AI_SUB:-} ${PAS_AUTH_SUB:-} ${PAS_LE_EMAIL:-}"
    ) <<<"$input" 2>/dev/null || echo DIED
}

expect() {
    local name=$1 want=$2 got=$3
    if [[ $got == "$want" ]]; then echo "PASS: $name"
    else echo "FAIL: $name — wanted '$want', got '$got'"; fails=$((fails + 1)); fi
}

expect "Enter keeps the HomeLab default" \
    "homelab" "$(run '' $'\n' | xargs)"

expect "VPS asks domain, all three subdomains and email" \
    "vps example.com paperless ai login admin@example.com" \
    "$(run '' $'2\nexample.com\npaperless\nai\nlogin\nadmin@example.com\n')"

expect "VPS subdomain defaults when Enter is pressed" \
    "vps example.org docs ai-docs auth ops@example.org" \
    "$(run '' $'2\nexample.org\n\n\n\nops@example.org\n')"

expect "Duplicate subdomains are asked again" \
    "vps example.org docs ai auth ops@example.org" \
    "$(run '' $'2\nexample.org\ndocs\ndocs\nauth\ndocs\nai\nauth\nops@example.org\n')"

expect "Invalid subdomain is asked again" \
    "vps example.org docs ai-docs auth ops@example.org" \
    "$(run '' $'2\nexample.org\nbad_label!\ndocs\n\n\nops@example.org\n')"

expect "Unattended: values from the environment are kept" \
    "vps example.com paperless ai login admin@example.com" \
    "$(run 'NONINTERACTIVE=1 PAS_TARGET=vps PAS_DOMAIN=example.com PAS_DOCS_SUB=paperless PAS_AI_SUB=ai PAS_AUTH_SUB=login PAS_LE_EMAIL=admin@example.com' '')"

expect "Unattended with nothing set installs HomeLab" \
    "homelab" "$(run 'NONINTERACTIVE=1' '' | xargs)"

expect "Unattended duplicate subdomains stop the install" \
    "DIED" "$(run 'NONINTERACTIVE=1 PAS_TARGET=vps PAS_DOMAIN=example.org PAS_DOCS_SUB=x PAS_AI_SUB=x PAS_AUTH_SUB=y PAS_LE_EMAIL=ops@example.org' '')"

(( fails == 0 )) && echo "RESULT: ALL TARGET QUESTION CHECKS PASSED" || { echo "RESULT: $fails FAILED"; exit 1; }
