#!/usr/bin/env bash
################################################################################
# Paperless Arabic Stack - One-command installer
#
#   Paperless-ngx + Paperless-GPT, tuned for Arabic documents.
#
#   Created for: Mahmoud Alkhatib  -  youtube.com/@malkhatib
#
#   Usage:
#     ./install.sh              install (or re-configure an existing install)
#     ./install.sh status       show what is running and where
#     ./install.sh update       pull the pinned images again and restart
#     ./install.sh backup       DB + documents + prompts/config -> ./backups
#     ./install.sh restore F    restore from a backup archive
#     ./install.sh uninstall    stop the stack (your documents are kept)
#     ./install.sh help
#
#   Every setting is stored in ./.env (chmod 600). Nothing is sent anywhere
#   unless you explicitly choose the cloud AI option.
################################################################################

# shellcheck disable=SC2034 # Settings persisted through indirect expansion in env_set.
set +x  # Secrets must never reach shell traces, even with bash -x.
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2.0.0-dev"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
CONFIG_DIR="$SCRIPT_DIR/config"
GPTDB_DIR="$SCRIPT_DIR/db"
CONSUME_DIR="$SCRIPT_DIR/consume"
EXPORT_DIR="$SCRIPT_DIR/export"
BACKUP_DIR="$SCRIPT_DIR/backups"
COMPOSE_PROJECT="paperless-ar"

# ------------------------------------------------------------------------------
# Pinned versions. These exact tags are what we tested. `update` re-pulls them;
# to move to a newer release, change the value in .env and run ./install.sh update
# ------------------------------------------------------------------------------
DEF_V_NGX="3.3.0"
DEF_V_GPT="v0.29.0"
DEF_V_OLLAMA="0.40.2"
DEF_V_POSTGRES="18.6"
DEF_V_VALKEY="9.1.2-alpine"
DEF_V_GOTENBERG="8.37.0"
DEF_V_TIKA="3.3.1.0"
DEF_V_TRAEFIK="v3.7.16"

# Measured defaults (see the Phase 2 report): these two models are the ones that
# actually work on Arabic documents. Do NOT swap the vision model for minicpm-v.
DEF_TEXT_MODEL="qwen3:8b"
DEF_VISION_MODEL="qwen2.5vl:7b"

################################################################################
# Colours and printing
################################################################################

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'
    BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""; BOLD=""; NC=""
fi

print_header()  { echo; echo "${CYAN}${BOLD}========================================${NC}";
                  echo "${CYAN}${BOLD}$1${NC}";
                  echo "${CYAN}${BOLD}========================================${NC}"; echo; }
print_success() { echo "${GREEN}✓ $1${NC}"; }
print_error()   { echo "${RED}✗ $1${NC}" >&2; }
print_warning() { echo "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo "${BLUE}ℹ $1${NC}"; }
print_step()    { echo "${MAGENTA}→ $1${NC}"; }

# Steps 8 and 9 are optional (no AI / no local models), so the numbers are
# counted at runtime. Hard-coding them left a confusing "Step 8 ... Step 10".
STEP_NO=0
step_header() { STEP_NO=$(( STEP_NO + 1 )); print_header "Step ${STEP_NO}: $1"; }

die() { print_error "$1"; exit 1; }

on_error() {
    local code=$? line=${1:-?}
    if declare -F auth_resume >/dev/null; then auth_resume || true; fi
    echo
    print_error "Something went wrong (exit $code, line $line)."
    echo "  The operation did not complete. Settings are in ./.env; rollback backups are in ./backups."
    echo "  Look at the logs:   docker compose logs --tail 80"
    echo "  Then run again:     ./install.sh      (it is safe to re-run)"
    exit "$code"
}
trap 'on_error $LINENO' ERR

################################################################################
# Small helpers
################################################################################

command_exists() { command -v "$1" >/dev/null 2>&1; }

# A password/secret made of url-safe characters only, so it never breaks .env,
# YAML, a shell command, or a copy/paste into a browser.
#
# Note the shape of the pipeline: a bounded `head` FEEDS `tr`. Writing it the
# obvious way round -- `tr -dc ... < /dev/urandom | head -c N` -- makes head
# close the pipe as soon as it has N bytes, tr dies of SIGPIPE, and with
# `set -o pipefail` the whole script aborts with exit 141.
generate_secret() {
    local len=${1:-32} out=""
    while (( ${#out} < len )); do
        out+=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' || true)
    done
    printf '%s' "${out:0:len}"
}

# `grep -q` stops reading at the first match, which SIGPIPEs whatever is piping
# into it; under `pipefail` a successful match then reports 141. Everywhere we
# need "does this output contain X", capture first and match against a string.
contains() { grep -qE -- "$2" <<<"$1"; }

# Blanks out anything that looks like credential material on its way to the
# screen: Django password hashes (pbkdf2_sha256$...), the apr1 basic-auth hash,
# and 40-hex API tokens. Used on PostgreSQL error text, which quotes the row it
# choked on -- and a dump broken inside the auth_user table puts the admin's
# password hash in that row. Measured.
redact_secrets() {
    sed -E \
        -e 's/(pbkdf2_[a-z0-9]+|argon2|bcrypt[a-z0-9_]*|scrypt|sha1|md5|unsalted_[a-z0-9]+)\$[^[:space:]"'"'"']*/\1$<redacted>/g' \
        -e 's/\$apr1\$[^[:space:]"'"'"']*/$apr1$<redacted>/g' \
        -e 's/[0-9a-f]{40}/<redacted>/g'
}
contains_line() { grep -qxF -- "$2" <<<"$1"; }

validate_domain() {
    [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}
validate_label() {   # a single DNS label, e.g. "docs"
    [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}
validate_email() {
    [[ $1 =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}
# Let's Encrypt refuses to create an account for a reserved TLD, and the error it
# returns ("Domain name does not end with a valid public suffix") appears much
# later, buried in the Traefik log, long after the install looks finished. Catch
# it while we still have the user in front of us.
email_tld_is_reserved() {
    local tld=${1##*.}
    case ${tld,,} in
        example|invalid|local|localhost|test|internal|lan|home|corp) return 0 ;;
        *) return 1 ;;
    esac
}
validate_port() {
    [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

NONINTERACTIVE=0

# `restore` dumps the database it is about to replace first, unless you say no.
SAFETY_DUMP=1

# `restore` never silently overwrites the admin password in the restored
# database -- that password is the user's, and the backup is the right place for
# it. Only --reset-admin-password (or answering yes to the prompt) writes it.
RESET_ADMIN_PW=0

# What the live database says about the password in .env, filled in by verify()
# from pw_probe(): PAS_PW_MATCH / PAS_PW_DIFFERS / PAS_PW_NOUSER, or empty when
# we could not ask. summary() refuses to print a password this does not confirm.
#
# A re-run after the user changes their own password in Paperless leaves .env
# holding the install-time value, and the install path correctly does NOT
# overwrite it -- so .env is simply out of date. Printing it anyway put a dead
# password on screen (and on camera). The probe already existed for `restore`;
# the install path just never asked.
PAS_PW_STATE=""

# ask VAR "question" "default"
# If VAR already has a value (from .env or the environment) that value becomes
# the default, which is what makes a re-run keep your previous answers.
ask() {
    local __var=$1 __prompt=$2 __def=${3:-} __in=""
    local __cur=${!__var:-}
    [[ -n $__cur ]] && __def=$__cur
    if (( NONINTERACTIVE )); then
        [[ -z $__def ]] && die "non-interactive mode: $__var has no value and no default"
        printf -v "$__var" '%s' "$__def"
        printf '  %s%-52s%s %s\n' "$BLUE" "$__prompt" "$NC" "$__def"
        return 0
    fi
    if [[ -n $__def ]]; then
        read -r -p "${CYAN}${__prompt} [${__def}]: ${NC}" __in || true
    else
        read -r -p "${CYAN}${__prompt}: ${NC}" __in || true
    fi
    printf -v "$__var" '%s' "${__in:-$__def}"
}

# ask_validated VAR "question" "default" validator_fn "error message"
ask_validated() {
    local var=$1 prompt=$2 def=$3 fn=$4 msg=$5
    while true; do
        ask "$var" "$prompt" "$def"
        if "$fn" "${!var}"; then return 0; fi
        print_error "$msg"
        (( NONINTERACTIVE )) && die "non-interactive mode: $var=${!var} is not valid"
        printf -v "$var" '%s' ''
    done
}

# ask_yes_no VAR "question" "Y|N"   -> sets VAR to yes/no
ask_yes_no() {
    local __var=$1 __prompt=$2 __def=${3:-Y} __in=""
    local __cur=${!__var:-}
    if [[ -n $__cur ]]; then
        case $__cur in yes|true|1) __def=Y ;; no|false|0) __def=N ;; esac
    fi
    local __hint="[Y/n]"; [[ $__def == N ]] && __hint="[y/N]"
    if (( NONINTERACTIVE )); then
        [[ $__def == Y ]] && printf -v "$__var" '%s' yes || printf -v "$__var" '%s' no
        printf '  %s%-52s%s %s\n' "$BLUE" "$__prompt" "$NC" "${!__var}"
        return 0
    fi
    read -r -p "${CYAN}${__prompt} ${__hint}: ${NC}" __in || true
    __in=${__in:-$__def}
    case $__in in
        [Yy]*) printf -v "$__var" '%s' yes ;;
        *)     printf -v "$__var" '%s' no ;;
    esac
}

is_yes() { [[ ${1:-no} == yes ]]; }

# ask_choice VAR "question" default_index "label1" "label2" ...
ask_choice() {
    local __var=$1 __prompt=$2 __defidx=$3; shift 3
    local -a __opts=("$@")
    local __cur=${!__var:-} __i
    if [[ -n $__cur ]]; then
        for __i in "${!__opts[@]}"; do
            [[ ${__opts[$__i]} == "$__cur"* ]] && __defidx=$(( __i + 1 ))
        done
    fi
    echo
    print_info "$__prompt"
    for __i in "${!__opts[@]}"; do
        printf '  %s%d)%s %s\n' "$BOLD" "$(( __i + 1 ))" "$NC" "${__opts[$__i]}"
    done
    if (( NONINTERACTIVE )); then
        printf -v "$__var" '%s' "${__opts[$(( __defidx - 1 ))]%% *}"
        printf '  %s-> %s%s\n' "$BLUE" "${!__var}" "$NC"
        return 0
    fi
    local __in
    while true; do
        read -r -p "${CYAN}Choose [1-${#__opts[@]}] (default: ${__defidx}): ${NC}" __in || true
        __in=${__in:-$__defidx}
        if [[ $__in =~ ^[0-9]+$ ]] && (( __in >= 1 && __in <= ${#__opts[@]} )); then
            printf -v "$__var" '%s' "${__opts[$(( __in - 1 ))]%% *}"
            print_success "${__opts[$(( __in - 1 ))]}"
            return 0
        fi
        print_error "Please type a number between 1 and ${#__opts[@]}."
    done
}

# Read a secret without echoing it to the screen or the scrollback.
ask_secret() {
    local __var=$1 __prompt=$2 __in=""
    local __cur=${!__var:-}
    if [[ -n $__cur ]]; then
        if (( NONINTERACTIVE )); then print_info "$__prompt -> (kept existing value)"; return 0; fi
        local keep=Y
        read -r -p "${CYAN}${__prompt} — keep the key already saved in .env? [Y/n]: ${NC}" keep || true
        [[ ${keep:-Y} =~ ^[Yy]*$ ]] && return 0
    fi
    (( NONINTERACTIVE )) && die "non-interactive mode: $__var (API key) must be set in .env or the environment"
    while true; do
        read -r -s -p "${CYAN}${__prompt} (not shown on screen): ${NC}" __in || true
        echo
        if [[ -n $__in ]]; then printf -v "$__var" '%s' "$__in"; return 0; fi
        print_error "The key cannot be empty."
    done
}

port_in_use() {
    local port=$1 listening=""
    if command_exists ss; then
        listening=$(ss -H -ltn 2>/dev/null | awk '{print $4}')
    elif command_exists netstat; then
        listening=$(netstat -ltn 2>/dev/null | awk 'NR>2{print $4}')
    else
        return 1   # cannot tell; caller warns
    fi
    contains "$listening" "[:.]${port}\$"
}

have_port_tool() { command_exists ss || command_exists netstat; }

# compose interpolates the WHOLE file on every command, so the `:?` guard on
# PAPERLESS_API_TOKEN would make `pull` and the first `up` fail during install --
# the token can only be created after paperless-ngx is already running. Feed
# compose a placeholder until the real token exists. It is never written to
# .env, and paperless-gpt is not started during those phases.
# Every docker compose call gets </dev/null, because `docker compose` attaches
# and DRAINS our stdin even when nothing inside the container reads it. That ate
# the operator's answer to the restore prompt: with the answer piped in,
# `printf 'restore\ny\n' | ./install.sh restore <file>` took the default-no
# branch every single time, and no amount of fixing the prompt helped. It is not
# only `exec -T` -- `dc stop` / `dc up -d` do it too, so it is fixed here once
# rather than at thirty call sites.
#
# The two calls that really are fed something on stdin (loading a dump into
# psql) use dc_in instead.
dc() {
    if [[ -z ${PAPERLESS_API_TOKEN:-} ]]; then
        PAPERLESS_API_TOKEN="pending-install" docker compose "$@" </dev/null
    else
        docker compose "$@" </dev/null
    fi
}
dc_in() {
    if [[ -z ${PAPERLESS_API_TOKEN:-} ]]; then
        PAPERLESS_API_TOKEN="pending-install" docker compose "$@"
    else
        docker compose "$@"
    fi
}

# Total RAM in MB and free disk in GB for the install directory.
ram_mb()  { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }
disk_gb() { df -BG --output=avail "$SCRIPT_DIR" 2>/dev/null | tail -1 | tr -dc '0-9'; }

# Primary LAN address, for the "open it from another device" line.
lan_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    [[ -n $ip ]] && { echo "$ip"; return; }
    hostname -I 2>/dev/null | awk '{print $1}'
}

################################################################################
# .env handling
################################################################################

# Load .env into the environment so every prompt can default to the old answer.
load_env() {
    [[ -f $ENV_FILE ]] || return 0
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
}

# env_set KEY VALUE  — write into .env, replacing any previous line for KEY.
#
# Values are always single-quoted. This is not cosmetic: a basic-auth hash looks
# like  admin:$apr1$Xy$zzz  and an unquoted value gets mangled the moment
# anything sources this file ($apr1 expands to nothing). Both `source` and the
# docker compose dotenv parser strip single quotes, so quoting is safe for both.
env_set() {
    local key=$1 val=$2 tmp
    if [[ $val == *"'"* ]]; then
        print_warning "Removed a single quote from the value of $key (it cannot be stored in .env)."
        val=${val//\'/}
    fi
    tmp=$(mktemp "$SCRIPT_DIR/.env.XXXXXX")
    chmod 600 "$tmp"
    if [[ -f $ENV_FILE ]]; then
        grep -v "^${key}=" "$ENV_FILE" > "$tmp" || true
    fi
    printf "%s='%s'\n" "$key" "$val" >> "$tmp"
    mv -f "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

################################################################################
# Banner
################################################################################

banner() {
    clear 2>/dev/null || true
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║      📄 Paperless Arabic Stack — Installer 📄             ║
║                                                           ║
║              Created by: Mahmoud Alkhatib                 ║
║         YouTube: youtube.com/@malkhatib                   ║
║         Website: malkhatib.com                            ║
║                                                           ║
║   ────────────────────────────────────────────────────    ║
║                                                           ║
║   What you get:                                           ║
║   ✓ Paperless-ngx   — your document archive               ║
║   ✓ Paperless-GPT   — AI reading + auto metadata          ║
║   ✓ PostgreSQL + Valkey + Gotenberg + Tika                ║
║   ✓ Arabic OCR, ready out of the box                      ║
║   ⭐ Ollama (local AI)  — optional                        ║
║   ⭐ Traefik + free SSL — optional (VPS with a domain)    ║
║                                                           ║
║   أرشفة مستنداتك العربية بالذكاء الاصطناعي                ║
║   Your Arabic documents, searchable with AI               ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo
    print_info "Installer version $SCRIPT_VERSION  —  install directory: $SCRIPT_DIR"
    echo
}

################################################################################
# STEP 1: Pre-flight checks
################################################################################

install_docker() {
    local ans=Y
    print_warning "Docker is not installed."
    if ! (( NONINTERACTIVE )); then
        read -r -p "${CYAN}Install Docker now with the official script (get.docker.com)? [Y/n]: ${NC}" ans || true
    fi
    if [[ ${ans:-Y} =~ ^[Nn] ]]; then
        die "Docker is required. Install it, then run ./install.sh again."
    fi
    local sudo_cmd=""
    (( EUID != 0 )) && sudo_cmd="sudo"
    if (( EUID != 0 )) && ! command_exists sudo; then
        die "Need root or sudo to install Docker. Run this script as root."
    fi
    print_step "Downloading and running the official Docker install script..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh \
        || die "Could not download the Docker install script. Check your internet connection."
    $sudo_cmd sh /tmp/get-docker.sh || die "The Docker install script failed."
    rm -f /tmp/get-docker.sh
    $sudo_cmd systemctl enable --now docker 2>/dev/null || true
    command_exists docker || die "Docker still not found after installing."
    print_success "Docker installed"

    if (( EUID != 0 )); then
        if ! docker info >/dev/null 2>&1; then
            $sudo_cmd usermod -aG docker "$USER" 2>/dev/null || true
            print_warning "You were added to the 'docker' group."
            echo "  Log out and back in (or run: newgrp docker), then run ./install.sh again."
            exit 0
        fi
    fi
}

precheck() {
    step_header "Checking this machine"

    # --- OS ---
    local os_name="unknown" os_ver=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        os_name=$(. /etc/os-release && echo "${NAME:-unknown}")
        os_ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
    fi
    print_info "Operating system: $os_name $os_ver"
    case $os_name in
        *Ubuntu*|*Debian*) print_success "Supported — Docker can be installed automatically if missing" ;;
        *) print_warning "Tested on Ubuntu/Debian. Other systems usually work, but you may have to install Docker yourself." ;;
    esac

    # --- CPU architecture ---
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)  print_success "CPU architecture: $ARCH (amd64) — all images available" ;;
        aarch64|arm64) print_success "CPU architecture: $ARCH (arm64) — all images available" ;;
        *) die "CPU architecture '$ARCH' is not supported. This stack needs amd64 or arm64." ;;
    esac

    # --- Docker ---
    if command_exists docker; then
        print_success "Docker found (version $(docker --version | awk '{print $3}' | tr -d ,))"
    else
        install_docker
    fi
    if docker compose version >/dev/null 2>&1; then
        print_success "Docker Compose found (version $(docker compose version --short))"
    else
        die "Docker Compose v2 plugin is missing. On Ubuntu/Debian: apt-get install docker-compose-plugin"
    fi
    if docker info >/dev/null 2>&1; then
        print_success "Docker daemon is running"
    else
        print_error "Cannot talk to the Docker daemon."
        echo "  Start it with:  sudo systemctl start docker"
        echo "  Or add yourself to the docker group:  sudo usermod -aG docker \$USER  (then log out and back in)"
        exit 1
    fi

    # --- tools ---
    command_exists openssl || print_warning "openssl not found — using /dev/urandom for passwords instead (that is fine)."
    command_exists curl    || die "curl is required. Install it with: apt-get install -y curl"
    command_exists tar     || die "tar is required. Install it with: apt-get install -y tar"

    # --- RAM ---
    RAM_MB=$(ram_mb)
    print_info "Memory (RAM): $(( RAM_MB / 1024 )) GB"
    if (( RAM_MB < 3500 )); then
        print_warning "Less than 4 GB of RAM. Paperless-ngx alone will be tight. Local AI will not work."
    elif (( RAM_MB < 15000 )); then
        print_info "Enough for Paperless-ngx. For local AI you really want 16 GB — we will warn you again if you pick it."
    else
        print_success "Plenty of RAM"
    fi

    # --- Disk ---
    DISK_GB=$(disk_gb)
    print_info "Free disk space here: ${DISK_GB} GB"
    if (( DISK_GB < 15 )); then
        print_warning "Under 15 GB free. The images alone need about 6 GB, and local AI models another ~11 GB."
    else
        print_success "Enough disk space to start"
    fi

    # --- GPU ---
    GPU_AVAILABLE=no
    if command_exists nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
        local dinfo; dinfo=$(docker info 2>/dev/null || true)
        if contains "$dinfo" '[Nn][Vv][Ii][Dd][Ii][Aa]'; then
            GPU_AVAILABLE=yes
            print_success "NVIDIA GPU found and usable from Docker: $(nvidia-smi -L | head -1)"
        else
            print_warning "NVIDIA GPU found, but Docker cannot use it (NVIDIA Container Toolkit is not installed)."
            echo "  Install it, or local AI will run on the CPU (much slower)."
        fi
    fi

    # --- ports ---
    if ! have_port_tool; then
        print_warning "Neither 'ss' nor 'netstat' is available, so I cannot check which ports are busy."
    fi
    print_success "Pre-flight checks finished"
}

# Is this port held by one of OUR OWN containers? On a re-run our stack is
# already listening, and refusing to continue because of that would make the
# whole thing non-idempotent -- which is exactly what happened before this check
# existed: the second ./install.sh aborted with "port 8000 is busy".
port_owned_by_us() {
    local port=$1 ids
    ids=$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}")
    [[ -n $ids ]] || return 1
    # Docker's human-readable Ports column compresses consecutive ports into ranges.
    # Inspect structured bindings so reruns recognize 8443-8444 correctly.
    # shellcheck disable=SC2086
    docker inspect --format '{{json .NetworkSettings.Ports}}' $ids | python3 -c '
import json,sys
wanted=sys.argv[1]
owned=any(binding.get("HostPort")==wanted
          for line in sys.stdin for bindings in (json.loads(line) or {}).values()
          for binding in (bindings or []))
sys.exit(0 if owned else 1)
' "$port"
}

check_port_or_ask() {   # check_port_or_ask VAR "what it is for"
    local var=$1 what=$2
    while port_in_use "${!var}"; do
        if port_owned_by_us "${!var}"; then
            print_success "Port ${!var} is already served by this stack ($what) — nothing to change"
            return 0
        fi
        print_warning "Port ${!var} ($what) is already used by something else on this machine."
        (( NONINTERACTIVE )) && die "non-interactive mode: port ${!var} is busy; set $var to a free port"
        printf -v "$var" '%s' ''
        ask_validated "$var" "Pick a different port for $what" "" validate_port "That is not a valid port number (1-65535)."
    done
    print_success "Port ${!var} is free ($what)"
}

################################################################################
# STEP 2: Questions
################################################################################

ask_config() {
    step_header "A few questions"

    PAS_TARGET=${PAS_TARGET:-homelab}
    if [[ $PAS_TARGET == vps ]]; then
        ask_validated PAS_DOMAIN "Your domain" "" validate_domain "A valid public domain is required."
        PAS_DOCS_SUB=${PAS_DOCS_SUB:-docs}
        PAS_AI_SUB=${PAS_AI_SUB:-ai-docs}
        PAS_AUTH_SUB=${PAS_AUTH_SUB:-auth}
        local label
        for label in "$PAS_DOCS_SUB" "$PAS_AI_SUB" "$PAS_AUTH_SUB"; do
            validate_label "$label" || die "Invalid service subdomain."
        done
        [[ $PAS_DOCS_SUB != "$PAS_AI_SUB" && $PAS_AUTH_SUB != "$PAS_AI_SUB" && $PAS_AUTH_SUB != "$PAS_DOCS_SUB" ]] \
            || die "Archive, AI and authentication subdomains must be different."
        ask_validated PAS_LE_EMAIL "Email for Let's Encrypt" "" validate_email "A real email address is required."
        email_tld_is_reserved "$PAS_LE_EMAIL" && die "Let's Encrypt requires a real email domain."
        PAS_LE_STAGING=${PAS_LE_STAGING:-no}
        PAS_HTTP_PORT=80
        print_info "DNS must point docs, AI and auth subdomains to this server; it will be checked before startup."
        if port_in_use 80 && ! port_owned_by_us 80; then die "Port 80 is required for Let's Encrypt."; fi
    elif [[ $PAS_TARGET == homelab ]]; then
        PAS_HTTP_PORT=443
        PAS_GPT_BIND=127.0.0.1
        PAS_GPT_PORT=8444
        PAS_GPT_LAN=no
        print_info "HomeLab: HTTPS by LAN IP. Trust the generated local CA on each client device."
    else
        die "PAS_TARGET must be homelab or vps."
    fi

    # ------------------------------------------------------------ languages --
    echo
    echo "What language are your documents in? This sets up OCR (reading text out of scans)."
    ask_choice PAS_DOC_LANG "Document language" 3 \
        "arabic   — Arabic only" \
        "english  — English only" \
        "both     — Arabic and English (most common in the Gulf)"
    # These two variables take DIFFERENT formats, and getting it wrong fails
    # silently. Verified against the image's own init script
    # (/etc/s6-overlay/s6-rc.d/init-tesseract-langs/run, v3.3.0):
    #   PAPERLESS_OCR_LANGUAGES -> SPACE-separated list; each entry becomes the
    #                              apt package tesseract-ocr-<entry>
    #   PAPERLESS_OCR_LANGUAGE  -> the language used to read a document, joined
    #                              with "+"
    # Writing "ara+eng" into the first one asks apt for a package called
    # tesseract-ocr-ara+eng, which does not exist. The container logs one line
    # ("Package not found! :(") and starts anyway -- with no Arabic OCR at all.
    case $PAS_DOC_LANG in
        arabic)  PAS_OCR_LANGUAGES="ara";     PAS_OCR_LANGUAGE="ara" ;;
        english) PAS_OCR_LANGUAGES="eng";     PAS_OCR_LANGUAGE="eng" ;;
        both|*)  PAS_OCR_LANGUAGES="ara eng"; PAS_OCR_LANGUAGE="ara+eng" ;;
    esac
    print_info "OCR language packs to install: $PAS_OCR_LANGUAGES"
    print_info "OCR reading language: $PAS_OCR_LANGUAGE"

    # ------------------------------------------------------------------- AI --
    echo
    echo "Now the AI part. This is what reads a phone photo of an Arabic invoice properly."
    ask_choice PAS_AI_MODE "How should the AI run?" 1 \
        "local    — Ollama on this machine. Nothing leaves your server. Slower." \
        "cloud    — a cloud API (OpenRouter / OpenAI / Gemini). Much faster and more accurate. Your documents leave your server." \
        "none     — install Paperless-ngx only, no AI for now"

    case $PAS_AI_MODE in
    local)
        # On a re-run that keeps the previous answers, trust what is in .env.
        # Re-probing here would flip a stored "container" to "external" just
        # because our own Ollama is now up and answering.
        if (( NONINTERACTIVE )) && [[ -n ${PAS_OLLAMA_MODE:-} && ${PAS_OLLAMA_MODE} != none ]]; then
            print_info "Keeping the saved AI setup: $PAS_OLLAMA_MODE ${PAS_OLLAMA_URL:+($PAS_OLLAMA_URL)}"
        else
            PAS_OLLAMA_MODE="container"
            # Is Ollama already running somewhere we can reach?
            local found=""
            for url in "http://127.0.0.1:11434" "http://host.docker.internal:11434"; do
                if curl -fsS --max-time 3 "${url}/api/tags" >/dev/null 2>&1; then found=$url; break; fi
            done
            if [[ -n $found ]]; then
                print_success "Found an Ollama already running at $found"
                ask_yes_no PAS_USE_EXISTING_OLLAMA "Use that existing Ollama instead of installing another one?" Y
                if is_yes "$PAS_USE_EXISTING_OLLAMA"; then
                    PAS_OLLAMA_MODE="external"
                    # Containers cannot reach the host on 127.0.0.1, so rewrite it.
                    if [[ $found == http://127.0.0.1:11434 ]]; then
                        PAS_OLLAMA_URL="http://host.docker.internal:11434"
                    else
                        PAS_OLLAMA_URL=$found
                    fi
                fi
            else
                print_info "No Ollama found on this machine — I will install it as part of the stack."
                ask_yes_no PAS_OLLAMA_REMOTE "Do you have Ollama running on ANOTHER machine you want to use? (e.g. a GPU box)" N
                if is_yes "$PAS_OLLAMA_REMOTE"; then
                    PAS_OLLAMA_MODE="external"
                    PAS_OLLAMA_URL=""
                    ask PAS_OLLAMA_URL "Full URL of that Ollama" "http://192.0.2.10:11434"
                    if curl -fsS --max-time 5 "${PAS_OLLAMA_URL}/api/tags" >/dev/null 2>&1; then
                        print_success "Reached $PAS_OLLAMA_URL"
                    else
                        print_warning "Could not reach $PAS_OLLAMA_URL from here. I will continue, but check it later."
                    fi
                fi
            fi
        fi

        ask PAS_TEXT_MODEL   "Text model (titles, dates, sender, tags)" "$DEF_TEXT_MODEL"
        ask PAS_VISION_MODEL "Vision model (reads images and scans)"   "$DEF_VISION_MODEL"
        if [[ $PAS_VISION_MODEL == minicpm-v* ]]; then
            print_warning "We measured minicpm-v on Arabic: it loops and scores WORSE than no AI at all."
            echo "  Strongly recommended instead: $DEF_VISION_MODEL"
        fi

        # RAM reality check
        if (( RAM_MB < 8000 )); then
            print_error "You have $(( RAM_MB / 1024 )) GB of RAM. The vision model alone needs about 8 GB."
            echo "  Local AI will either fail or swap to disk and take forever."
            echo "  Pick the cloud option, or add more RAM."
            local go=N
            if ! (( NONINTERACTIVE )); then
                read -r -p "${CYAN}Continue anyway? [y/N]: ${NC}" go || true
                [[ ${go:-N} =~ ^[Yy] ]] || die "Stopped. Re-run ./install.sh and choose the cloud option."
            fi
        elif (( RAM_MB < 15000 )); then
            print_warning "We measured a peak of 7.8 GB for the vision model. With $(( RAM_MB / 1024 )) GB you can run one model at a time, but it will be tight."
        fi

        if (( NONINTERACTIVE )) && [[ -n ${PAS_GPU:-} ]]; then
            print_info "Keeping the saved GPU setting: $PAS_GPU"
        else
            PAS_GPU=no
            if [[ $PAS_OLLAMA_MODE == container && $GPU_AVAILABLE == yes ]]; then
                ask_yes_no PAS_USE_GPU "Let Ollama use your NVIDIA GPU? (strongly recommended)" Y
                is_yes "$PAS_USE_GPU" && PAS_GPU=yes
            fi
        fi
        if [[ $PAS_GPU == no && $PAS_OLLAMA_MODE == container ]]; then
            print_warning "No GPU: reading one phone photo takes about 6-8 minutes on 4 CPU cores. That is normal, not broken."
        fi
        PAS_CLOUD_BASE_URL=""
        PAS_CLOUD_MODEL=""
        ;;
    cloud)
        echo
        print_warning "Cloud mode sends the page image and text of every processed document to that provider."
        echo "  Do not use it for documents you are not allowed to send outside your server."
        ask_choice PAS_CLOUD_PROVIDER "Which provider?" 1 \
            "openrouter — OpenRouter (one key, many models; what we measured)" \
            "openai     — OpenAI directly" \
            "gemini     — Google Gemini (OpenAI-compatible endpoint)" \
            "custom     — any other OpenAI-compatible endpoint"
        case $PAS_CLOUD_PROVIDER in
            openrouter)
                PAS_CLOUD_BASE_URL="https://openrouter.ai/api/v1"
                ask PAS_CLOUD_MODEL "Model name" "google/gemini-3.1-flash-lite" ;;
            openai)
                PAS_CLOUD_BASE_URL="https://api.openai.com/v1"
                ask PAS_CLOUD_MODEL "Model name" "gpt-4o-mini" ;;
            gemini)
                PAS_CLOUD_BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai"
                # Same model we measured via OpenRouter, under Google's own ID. gemini-2.5-flash
                # is no longer offered to new API accounts.
                ask PAS_CLOUD_MODEL "Model name" "gemini-3.1-flash-lite" ;;
            custom)
                ask PAS_CLOUD_BASE_URL "Base URL of the OpenAI-compatible endpoint" "https://"
                ask PAS_CLOUD_MODEL    "Model name" "" ;;
        esac
        ask_secret PAS_CLOUD_API_KEY "API key for ${PAS_CLOUD_PROVIDER}"
        PAS_TEXT_MODEL="$PAS_CLOUD_MODEL"
        PAS_VISION_MODEL="$PAS_CLOUD_MODEL"
        PAS_OLLAMA_MODE="none"
        PAS_GPU=no
        print_info "We measured roughly \$0.0013 per document end to end — about 5 SAR per 1000 documents."
        ;;
    none|*)
        PAS_OLLAMA_MODE="none"
        PAS_GPU=no
        PAS_TEXT_MODEL=""
        PAS_VISION_MODEL=""
        PAS_CLOUD_BASE_URL=""
        PAS_CLOUD_MODEL=""
        print_info "Paperless-ngx only. You can add the AI later: run ./install.sh again and pick local or cloud."
        ;;
    esac

    # ------------------------------------------------------------- timezone --
    echo
    ask_choice PAS_TZ "Your timezone" 1 \
        "Asia/Riyadh" "Asia/Dubai" "Asia/Kuwait" "Asia/Qatar" "Asia/Bahrain" \
        "Africa/Cairo" "Europe/London" "UTC" "custom"
    if [[ $PAS_TZ == custom ]]; then
        PAS_TZ=""
        ask PAS_TZ "Timezone (e.g. Asia/Riyadh)" "Asia/Riyadh"
    fi

    # -------------------------------------------------------- admin account --
    echo
    ask PAS_ADMIN_USER "Admin username for Paperless-ngx" "admin"
    ask PAS_ADMIN_MAIL "Admin email" "admin@${PAS_DOMAIN:-localhost}"

    # Which user the apps run as INSIDE their containers. Installing as root is
    # normal on a VPS, but that is no reason to run Paperless as root too, so
    # fall back to 1000 and chown the bind-mounted folders to match.
    if (( EUID == 0 )); then
        PAS_PUID=${PAS_PUID:-1000}
        PAS_PGID=${PAS_PGID:-1000}
    else
        PAS_PUID=$(id -u)
        PAS_PGID=$(id -g)
    fi
}

################################################################################
# STEP 3: Secrets and .env
################################################################################

write_env() {
    step_header "Passwords and settings"

    # Secrets are generated once and then reused on every re-run.
    PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET_KEY:-$(generate_secret 50)}
    PAPERLESS_DBPASS=${PAPERLESS_DBPASS:-$(generate_secret 32)}
    PAS_ADMIN_PASSWORD=${PAS_ADMIN_PASSWORD:-$(generate_secret 20)}

    [[ -f $ENV_FILE ]] || { : > "$ENV_FILE"; chmod 600 "$ENV_FILE"; }

    local k
    for k in PAS_TARGET PAS_DOMAIN PAS_DOCS_SUB PAS_AI_SUB PAS_AUTH_SUB PAS_LE_EMAIL PAS_LE_STAGING \
             PAS_HTTP_PORT PAS_GPT_BIND PAS_GPT_PORT PAS_GPT_LAN \
             PAS_DOC_LANG PAS_OCR_LANGUAGES PAS_OCR_LANGUAGE PAS_TZ \
             PAS_AI_MODE PAS_OLLAMA_MODE PAS_OLLAMA_URL PAS_TEXT_MODEL PAS_VISION_MODEL PAS_GPU \
             PAS_CLOUD_PROVIDER PAS_CLOUD_BASE_URL PAS_CLOUD_MODEL \
             PAS_ADMIN_USER PAS_ADMIN_MAIL PAS_ADMIN_PASSWORD PAS_PUID PAS_PGID \
             PAS_BASIC_AUTH_USER PAS_BASIC_AUTH_PASS PAS_BASIC_AUTH_HASH PAS_BASIC_AUTH_FP \
             PAPERLESS_SECRET_KEY PAPERLESS_DBPASS PAS_CLOUD_API_KEY; do
        env_set "$k" "${!k:-}"
    done

    # Image versions live in .env so `update` can move them without editing compose.yaml.
    env_set PAS_V_NGX        "${PAS_V_NGX:-$DEF_V_NGX}"
    env_set PAS_V_GPT        "${PAS_V_GPT:-$DEF_V_GPT}"
    env_set PAS_V_OLLAMA     "${PAS_V_OLLAMA:-$DEF_V_OLLAMA}"
    env_set PAS_V_POSTGRES   "${PAS_V_POSTGRES:-$DEF_V_POSTGRES}"
    env_set PAS_V_VALKEY     "${PAS_V_VALKEY:-$DEF_V_VALKEY}"
    env_set PAS_V_GOTENBERG  "${PAS_V_GOTENBERG:-$DEF_V_GOTENBERG}"
    env_set PAS_V_TIKA       "${PAS_V_TIKA:-$DEF_V_TIKA}"
    env_set PAS_V_TRAEFIK    "${PAS_V_TRAEFIK:-$DEF_V_TRAEFIK}"

    load_env
    print_success "Settings and passwords written to .env (chmod 600, never commit this file)"
}

################################################################################
# STEP 4: compose.yaml
################################################################################

write_compose() {
    step_header "Writing compose.yaml"

    local tmp; tmp=$(mktemp "$SCRIPT_DIR/compose.yaml.XXXXXX")

    local ngx_networks="[internal]"
    [[ $PAS_TARGET == vps ]] && ngx_networks="[internal, web]"

    # ---------- header ----------
    cat >> "$tmp" <<YAML
# Generated by install.sh $SCRIPT_VERSION -- do NOT hand-edit.
# There is deliberately no timestamp in here: that would make the file differ on
# every re-run, which churns your backups and your git diffs for no reason. The
# install date is in INSTALLATION_INFO.txt.
# ./install.sh rewrites this file from your answers in .env.
# To change a setting, run ./install.sh again. To change an image version,
# edit the PAS_V_* value in .env and run ./install.sh update
name: $COMPOSE_PROJECT

services:
  broker:
    image: docker.io/valkey/valkey:\${PAS_V_VALKEY}
    restart: unless-stopped
    volumes:
      - redisdata:/data
    networks: [internal]

  db:
    image: docker.io/library/postgres:\${PAS_V_POSTGRES}
    restart: unless-stopped
    volumes:
      - pgdata:/var/lib/postgresql
    environment:
      POSTGRES_DB: paperless
      POSTGRES_USER: paperless
      POSTGRES_PASSWORD: \${PAPERLESS_DBPASS:?PAPERLESS_DBPASS must be set in .env}
    networks: [internal]

  gotenberg:
    image: docker.io/gotenberg/gotenberg:\${PAS_V_GOTENBERG}
    restart: unless-stopped
    # Converts Office files and .eml to PDF. JavaScript off, no remote content.
    command:
      - "gotenberg"
      - "--chromium-disable-javascript=true"
      - "--chromium-allow-list=file:///tmp/.*"
    networks: [internal]

  tika:
    image: docker.io/apache/tika:\${PAS_V_TIKA}
    restart: unless-stopped
    networks: [internal]

  webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:\${PAS_V_NGX}
    restart: unless-stopped
    depends_on: [db, broker, gotenberg, tika]
YAML

    # ---------- paperless-ngx ports ----------
    if [[ $PAS_TARGET == vps ]]; then
        cat >> "$tmp" <<'YAML'
    # VPS mode: no published port. The only way in is Traefik on 80/443.
YAML
    else
        cat >> "$tmp" <<YAML
    ports:
      - "\${PAS_HTTP_PORT}:8000"
YAML
    fi

    cat >> "$tmp" <<YAML
    volumes:
      - data:/usr/src/paperless/data
      - media:/usr/src/paperless/media
      - ./export:/usr/src/paperless/export
      - ./consume:/usr/src/paperless/consume
    # Secrets are listed one by one on purpose. Using "env_file: .env" would
    # also hand this container the cloud API key, which it has no use for.
    environment:
      PAPERLESS_SECRET_KEY: \${PAPERLESS_SECRET_KEY:?PAPERLESS_SECRET_KEY must be set in .env}
      PAPERLESS_DBPASS: \${PAPERLESS_DBPASS:?PAPERLESS_DBPASS must be set in .env}
      PAPERLESS_ADMIN_USER: \${PAS_ADMIN_USER}
      PAPERLESS_ADMIN_PASSWORD: \${PAS_ADMIN_PASSWORD}
      PAPERLESS_ADMIN_MAIL: \${PAS_ADMIN_MAIL}
      PAPERLESS_REDIS: redis://broker:6379
      PAPERLESS_DBENGINE: postgresql
      PAPERLESS_DBHOST: db
      PAPERLESS_DBNAME: paperless
      PAPERLESS_DBUSER: paperless
      PAPERLESS_TIKA_ENABLED: 1
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT: http://gotenberg:3000
      PAPERLESS_TIKA_ENDPOINT: http://tika:9998
      # --- OCR / region ---
      # PAPERLESS_OCR_LANGUAGES installs the tesseract language packages;
      # PAPERLESS_OCR_LANGUAGE is the language actually used to read a document.
      PAPERLESS_OCR_LANGUAGES: "\${PAS_OCR_LANGUAGES}"
      PAPERLESS_OCR_LANGUAGE: "\${PAS_OCR_LANGUAGE}"
      PAPERLESS_TIME_ZONE: \${PAS_TZ}
      PAPERLESS_DATE_ORDER: DMY
      PAPERLESS_DATE_PARSER_LANGUAGES: ar+en
      USERMAP_UID: \${PAS_PUID}
      USERMAP_GID: \${PAS_PGID}
YAML

    if [[ $PAS_TARGET == vps ]]; then
        cat >> "$tmp" <<YAML
      # Required behind a reverse proxy: sets ALLOWED_HOSTS and CSRF origins.
      PAPERLESS_URL: https://\${PAS_DOCS_SUB}.\${PAS_DOMAIN}
    labels:
      - traefik.enable=true
      - traefik.docker.network=${COMPOSE_PROJECT}_web
      - traefik.http.routers.paperless.rule=Host(\`\${PAS_DOCS_SUB}.\${PAS_DOMAIN}\`)
      - traefik.http.routers.paperless.entrypoints=websecure
      - traefik.http.routers.paperless.tls.certresolver=le
      - traefik.http.services.paperless.loadbalancer.server.port=8000
YAML
    fi

    cat >> "$tmp" <<YAML
    networks: $ngx_networks
    healthcheck:
      test: ["CMD", "curl", "-fs", "-S", "--max-time", "2", "http://localhost:8000"]
      interval: 15s
      timeout: 10s
      retries: 20
      start_period: 120s
YAML

    # ---------- ollama ----------
    if [[ ${PAS_OLLAMA_MODE:-none} == container ]]; then
        # Measured: loading a model off disk costs ~15s and the GPU does not
        # speed that up. On a GPU that load is ~75% of the total time, so keep
        # the model resident. On a CPU the run itself takes minutes, so a short
        # keep-alive just frees 8 GB of RAM between documents.
        local keep_alive="10m"
        [[ $PAS_GPU == yes ]] && keep_alive="60m"
        cat >> "$tmp" <<YAML

  ollama:
    image: docker.io/ollama/ollama:\${PAS_V_OLLAMA}
    restart: unless-stopped
    # Deliberately no published port: only the other containers talk to it.
    volumes:
      - ollama:/root/.ollama
    environment:
      OLLAMA_KEEP_ALIVE: ${keep_alive}
      OLLAMA_NUM_PARALLEL: 1
      OLLAMA_MAX_LOADED_MODELS: 1
    networks: [internal]
YAML
        if [[ $PAS_GPU == yes ]]; then
            cat >> "$tmp" <<'YAML'
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
YAML
        fi
    fi

    # ---------- paperless-gpt ----------
    if [[ ${PAS_AI_MODE} != none ]]; then
        local gpt_networks="[internal]"
        [[ $PAS_TARGET == vps ]] && gpt_networks="[internal, web]"

        cat >> "$tmp" <<YAML

  # SECURITY: paperless-gpt has no login of its own.
  #   VPS mode     -> reachable only through Traefik, behind basic auth.
  #   HomeLab mode -> published on \${PAS_GPT_BIND} only.
  paperless-gpt:
    image: docker.io/icereed/paperless-gpt:\${PAS_V_GPT}
    restart: unless-stopped
    depends_on:
      webserver:
        condition: service_healthy
YAML
        [[ ${PAS_OLLAMA_MODE} == container ]] && cat >> "$tmp" <<'YAML'
      ollama:
        condition: service_started
YAML

        if [[ $PAS_TARGET == homelab ]]; then
            cat >> "$tmp" <<YAML
    ports:
      - "\${PAS_GPT_BIND}:\${PAS_GPT_PORT}:8080"
YAML
        fi

        cat >> "$tmp" <<YAML
    volumes:
      - ./prompts:/app/prompts
      - ./config:/app/config
      - ./db:/app/db
    environment:
      PUID: \${PAS_PUID}
      PGID: \${PAS_PGID}
      # --- link to paperless-ngx (inside the project network, no proxy) ---
      PAPERLESS_BASE_URL: http://webserver:8000
      PAPERLESS_API_TOKEN: \${PAPERLESS_API_TOKEN:?run ./install.sh to create the API token}
      # --- the tags that trigger the AI ---
      MANUAL_TAG: paperless-gpt
      AUTO_TAG: paperless-gpt-auto
      AUTO_OCR_TAG: paperless-gpt-ocr-auto
      FAIL_TAG: paperless-gpt-failed
      LLM_LANGUAGE: \${PAS_LLM_LANGUAGE}
      # Upstream default is false, and the tag prompt may only pick tags that
      # already exist. On a fresh install there are none, so the auto flow
      # produced ZERO tags until we turned this on.
      CREATE_NEW_TAGS: "true"
      # --- OCR through a vision model ---
      OCR_PROVIDER: llm
      OCR_PROCESS_MODE: image
      # Measured: the defaults (600 DPI / 10000 px) render a phone photo at
      # 4780x8365 and are the single biggest cost on a CPU-only host.
      IMAGE_MAX_RENDER_DPI: 150
      IMAGE_MAX_PIXEL_DIMENSION: 1600
      IMAGE_MAX_TOTAL_PIXELS: 2560000
      VISION_LLM_MAX_TOKENS: 4096
      VISION_LLM_TEMPERATURE: 0
      OCR_MAX_RETRIES: 1
      TOKEN_LIMIT: 1000
      SUGGESTION_WORKERS: 1
YAML

        if [[ $PAS_TARGET == vps ]]; then
            cat >> "$tmp" <<YAML
      PAPERLESS_PUBLIC_URL: https://\${PAS_DOCS_SUB}.\${PAS_DOMAIN}
YAML
        fi

        if [[ $PAS_AI_MODE == local ]]; then
            local ollama_host="http://ollama:11434"
            [[ $PAS_OLLAMA_MODE == external ]] && ollama_host="$PAS_OLLAMA_URL"
            cat >> "$tmp" <<YAML
      # --- local AI through Ollama ---
      LLM_PROVIDER: ollama
      VISION_LLM_PROVIDER: ollama
      OLLAMA_HOST: ${ollama_host}
      LLM_MODEL: \${PAS_TEXT_MODEL}
      VISION_LLM_MODEL: \${PAS_VISION_MODEL}
      OLLAMA_THINK: "false"
      OLLAMA_CONTEXT_LENGTH: 8192
      OLLAMA_TIMEOUT_SECONDS: 1800
YAML
            if [[ $PAS_OLLAMA_MODE == external && $PAS_OLLAMA_URL == *host.docker.internal* ]]; then
                cat >> "$tmp" <<'YAML'
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML
            fi
        else
            cat >> "$tmp" <<YAML
      # --- cloud AI. "openai" here means "OpenAI-compatible", not necessarily
      #     OpenAI: that is what upstream docs/openai_compatible_providers.md
      #     tells you to use for OpenRouter and friends.
      LLM_PROVIDER: openai
      VISION_LLM_PROVIDER: openai
      OPENAI_BASE_URL: \${PAS_CLOUD_BASE_URL}
      OPENAI_API_KEY: \${PAS_CLOUD_API_KEY:?the API key is missing from .env}
      LLM_MODEL: \${PAS_TEXT_MODEL}
      VISION_LLM_MODEL: \${PAS_VISION_MODEL}
YAML
        fi

        if [[ $PAS_TARGET == vps ]]; then
            # $ must be doubled in a compose label, otherwise compose eats the
            # apr1/bcrypt hash and basic auth silently never matches.
            local hash_escaped="disabled-replaced-by-authentik"
            cat >> "$tmp" <<YAML
    labels:
      - traefik.enable=true
      - traefik.docker.network=${COMPOSE_PROJECT}_web
      - traefik.http.routers.paperless-gpt.rule=Host(\`\${PAS_AI_SUB}.\${PAS_DOMAIN}\`)
      - traefik.http.routers.paperless-gpt.entrypoints=websecure
      - traefik.http.routers.paperless-gpt.tls.certresolver=le
      - traefik.http.routers.paperless-gpt.middlewares=gpt-auth
      - traefik.http.middlewares.gpt-auth.basicauth.users=${hash_escaped}
      - traefik.http.services.paperless-gpt.loadbalancer.server.port=8080
YAML
        fi
        cat >> "$tmp" <<YAML
    networks: $gpt_networks
YAML
    fi

    # ---------- traefik ----------
    if [[ $PAS_TARGET == vps ]]; then
        cat >> "$tmp" <<YAML

  # Traefik terminates TLS and gets free certificates from Let's Encrypt.
  # The docker socket is mounted read-only so Traefik can see the labels above.
  traefik:
    image: docker.io/traefik:\${PAS_V_TRAEFIK}
    restart: unless-stopped
    command:
      - --global.sendanonymoususage=false
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=${COMPOSE_PROJECT}_web
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.email=\${PAS_LE_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
YAML
        if is_yes "${PAS_LE_STAGING:-no}"; then
            cat >> "$tmp" <<'YAML'
      # STAGING: certificates are NOT trusted by browsers. Testing only.
      - --certificatesresolvers.le.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory
YAML
        fi
        cat >> "$tmp" <<'YAML'
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - letsencrypt:/letsencrypt
    networks: [web]
YAML
    fi

    # ---------- volumes and networks ----------
    cat >> "$tmp" <<'YAML'

volumes:
  data:
  media:
  pgdata:
  redisdata:
YAML
    [[ ${PAS_OLLAMA_MODE:-none} == container ]] && printf '  ollama:\n' >> "$tmp"
    [[ $PAS_TARGET == vps ]] && printf '  letsencrypt:\n' >> "$tmp"

    cat >> "$tmp" <<'YAML'

networks:
  internal:
YAML
    [[ $PAS_TARGET == vps ]] && printf '  web:\n' >> "$tmp"

    # LLM_LANGUAGE follows the document language the user picked.
    case $PAS_DOC_LANG in
        arabic|both) env_set PAS_LLM_LANGUAGE "Arabic" ;;
        *)           env_set PAS_LLM_LANGUAGE "English" ;;
    esac
    load_env

    local secure; secure=$(mktemp "$SCRIPT_DIR/compose.secure.XXXXXX")
    auth_render "$tmp" "$secure"
    rm -f "$tmp"
    mv -f "$secure" "$COMPOSE_FILE"
    chmod 600 "$COMPOSE_FILE"
    print_success "Secure compose.yaml written and validated"

}

################################################################################
# STEP 5: directories and prompts
################################################################################

write_prompts() {
    step_header "Folders and AI prompts"

    mkdir -p "$CONSUME_DIR" "$EXPORT_DIR" "$CONFIG_DIR" "$GPTDB_DIR" "$BACKUP_DIR" "$PROMPTS_DIR"
    # The containers run as PAS_PUID:PAS_PGID, so the bind-mounted folders have
    # to belong to that user or nothing can be written into them.
    if (( EUID == 0 )); then
        chown -R "${PAS_PUID}:${PAS_PGID}" \
            "$CONSUME_DIR" "$EXPORT_DIR" "$CONFIG_DIR" "$GPTDB_DIR" "$PROMPTS_DIR" 2>/dev/null || true
    fi
    print_success "Folders ready (drop files into ./consume to import them automatically)"

    [[ $PAS_AI_MODE == none ]] && { print_info "No AI selected — skipping prompts."; return 0; }

    # Seed the upstream default prompts straight out of the pinned image, so
    # they always match the version we are running. Existing files are kept.
    local img="docker.io/icereed/paperless-gpt:${PAS_V_GPT}"
    docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null
    local seeded=0 f
    while IFS= read -r f; do
        [[ -z $f ]] && continue
        # Anything we ship an Arabic version of is handled below. The upstream
        # copy must not land first, or it looks like a file the user edited and
        # ours is never installed.
        [[ -f "$SCRIPT_DIR/prompts-ar/$f" ]] && continue
        if [[ ! -f "$PROMPTS_DIR/$f" ]]; then
            docker run --rm --entrypoint cat "$img" "/app/default_prompts/$f" > "$PROMPTS_DIR/$f"
            seeded=$(( seeded + 1 ))
        fi
    done < <(docker run --rm --entrypoint sh "$img" -c 'ls -1 /app/default_prompts' 2>/dev/null)
    (( seeded )) && print_success "Copied $seeded default prompt template(s) from the paperless-gpt image"

    # Every template in prompts-ar/ replaces the upstream one of the same name.
    # Each is re-applied on upgrade as long as the operator has not edited it:
    # we remember the checksum we last wrote, so "same as we left it" means ours
    # to update and anything else means hands off.
    #
    #   ocr_prompt.tmpl  The upstream prompt ends with "Use markdown format" and
    #     a friendly tone, and the model then writes chatter like "Here is the
    #     transcribed text..." straight INTO the document. Replacing it moved
    #     text similarity from 82.7% to 90.0% on our test image.
    #
    #   tag_prompt.tmpl  The upstream prompt asks for "a comma-separated list"
    #     and paperless-gpt splits the answer on the ASCII comma only. A model
    #     answering in Arabic separates with the Arabic comma U+060C, so nothing
    #     splits and all 4-5 tags arrive as ONE tag named
    #     "فاتورة ضريبية، مستندات مالية، ..." (NOM-238). Worse, that tag then
    #     appears in <available_tags> on the next document and teaches the model
    #     the same separator, so the fault compounds. Ours pins the separator to
    #     the ASCII comma: 48/48 clean answers across the cloud and local text
    #     models, against 0/12 before.
    local shipped name target stamp new_sum cur_sum last_sum
    for shipped in "$SCRIPT_DIR"/prompts-ar/*.tmpl; do
        [[ -f $shipped ]] || continue
        name=$(basename "$shipped")
        target="$PROMPTS_DIR/$name"
        stamp="$PROMPTS_DIR/.${name%.tmpl}.installed.sha256"
        new_sum=$(sha256sum "$shipped" | awk '{print $1}')
        cur_sum=""; [[ -f $target ]] && cur_sum=$(sha256sum "$target" | awk '{print $1}')
        last_sum=""; [[ -f $stamp ]] && last_sum=$(cat "$stamp")
        if [[ -z $cur_sum ]]; then
            cp -f "$shipped" "$target"; printf '%s\n' "$new_sum" > "$stamp"
            print_success "Installed the Arabic-tuned prompt: $name"
        elif [[ $cur_sum == "$new_sum" ]]; then
            printf '%s\n' "$new_sum" > "$stamp"
            print_success "Arabic-tuned prompt already in place: $name"
        elif [[ -n $last_sum && $cur_sum == "$last_sum" ]]; then
            # Unchanged since we last wrote it, so it is ours to update.
            cp -f "$shipped" "$target"; printf '%s\n' "$new_sum" > "$stamp"
            print_success "Updated the Arabic-tuned prompt: $name"
        else
            print_info "You have edited prompts/$name — keeping your version."
        fi
    done

    # paperless-gpt writes its undo database and settings into these.
    [[ -f "$CONFIG_DIR/settings.json" ]] || echo '{}' > "$CONFIG_DIR/settings.json"
}

################################################################################
# STEP 6-8: bring it up, get the API token, finish
################################################################################

CORE_SERVICES=(db broker gotenberg tika webserver)

pull_images() {
    step_header "Downloading the images"
    print_info "First time this takes a few minutes. Later runs are fast."
    dc pull --quiet 2>/dev/null || dc pull
    print_success "All images downloaded"
}

start_core() {
    step_header "Starting Paperless-ngx"
    dc up -d "${CORE_SERVICES[@]}"
    dc up -d traefik
    print_info "Waiting for Paperless-ngx to finish its first-time setup..."
    if [[ $PAS_OCR_LANGUAGES != eng ]]; then
        print_info "(It installs the tesseract language pack on every boot, so the first boot is the slow one.)"
    fi

    # First boot does: install the language pack, then run every database
    # migration. On a small 2-vCPU VPS that genuinely takes several minutes, so
    # the budget here is deliberately generous (15 min) -- a timeout that is too
    # short just turns a slow server into a scary false failure.
    local tries=0 max=180
    until dc exec -T webserver curl -fsS --max-time 3 http://localhost:8000 >/dev/null 2>&1; do
        tries=$(( tries + 1 ))
        if (( tries >= max )); then
            print_error "Paperless-ngx did not come up within 15 minutes."
            echo "  Look at the logs:  docker compose logs --tail 60 webserver"
            echo "  Then just run ./install.sh again — it picks up where it stopped."
            exit 1
        fi
        if (( tries % 12 == 0 )); then
            printf '    ...still starting (%d min). First boot is the slow one.\n' $(( tries / 12 ))
        fi
        sleep 5
    done
    print_success "Paperless-ngx is up"

    local wlogs; wlogs=$(dc logs webserver 2>/dev/null || true)
    if contains "$wlogs" 'Created superuser'; then
        print_success "Admin user '$PAS_ADMIN_USER' created"
    else
        print_info "Admin user '$PAS_ADMIN_USER' already existed — password unchanged."
    fi
}

# Create (or reuse) the API token for the admin user and put it in .env, so the
# user never has to copy/paste it out of the web UI.
fetch_api_token() {
    [[ $PAS_AI_MODE == none ]] && return 0
    step_header "Connecting Paperless-GPT to Paperless-ngx"

    local token
    token=$(dc exec -T webserver python3 /usr/src/paperless/src/manage.py shell -c '
from rest_framework.authtoken.models import Token
from django.contrib.auth import get_user_model
u = get_user_model().objects.filter(is_superuser=True).order_by("id").first()
if u is None:
    print("PAS_NO_SUPERUSER")
else:
    t, _ = Token.objects.get_or_create(user=u)
    print("PAS_TOKEN=%s" % t.key)
' 2>/dev/null | grep -oE 'PAS_TOKEN=[0-9a-f]{40}' | cut -d= -f2 || true)

    if [[ -z $token ]]; then
        print_error "Could not create the API token automatically."
        echo "  Check the existing Paperless administrator and re-run ./install.sh; credentials are provisioned automatically."
        exit 1
    fi
    env_set PAPERLESS_API_TOKEN "$token"
    load_env
    print_success "API token created and injected into Paperless-GPT (nothing to copy by hand)"
}

api_tag_names() {
    dc exec -T webserver curl -fsS \
        -H "Authorization: Token ${PAPERLESS_API_TOKEN}" \
        "http://localhost:8000/api/tags/?page_size=200" 2>/dev/null \
      | tr ',' '\n' | grep -oE '"name":"[^"]*"' | cut -d'"' -f4 | sort || true
}

# paperless-gpt creates only its two OUTPUT tags on startup (-failed and
# -auto-complete). The three tags you actually need in order to TRIGGER it do
# not exist on a fresh install -- measured on a clean container, tag count 2.
# Without them a new user has nothing to tag a document with, and has to guess
# the exact spelling by hand. So we create them.
create_trigger_tags() {
    [[ $PAS_AI_MODE == none ]] && return 0
    step_header "Creating the AI trigger tags"

    local existing; existing=$(api_tag_names)
    local -a want=(paperless-gpt paperless-gpt-auto paperless-gpt-ocr-auto)
    local -a colour=("#1f78b4" "#33a02c" "#e31a1c")
    local i=0 t
    for t in "${want[@]}"; do
        if contains_line "$existing" "$t"; then
            print_success "Tag '$t' is already there"
        elif dc exec -T webserver curl -fsS -o /dev/null -X POST \
                -H "Authorization: Token ${PAPERLESS_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"name\":\"${t}\",\"color\":\"${colour[$i]}\",\"matching_algorithm\":0,\"match\":\"\",\"is_insensitive\":true}" \
                "http://localhost:8000/api/tags/" 2>/dev/null; then
            # matching_algorithm 0 is "None" (confirmed from the API's own
            # OPTIONS response). These tags must never attach themselves to a
            # document -- you put them on deliberately, to ask the AI for work.
            print_success "Created tag '$t'"
        else
            print_warning "Could not create the tag '$t'. Add it by hand in Paperless-ngx (exact spelling)."
        fi
        i=$(( i + 1 ))
    done
}

pull_models() {
    [[ $PAS_AI_MODE == local ]] || return 0
    [[ ${PAS_OLLAMA_MODE} == container ]] || {
        print_info "Using the Ollama at $PAS_OLLAMA_URL — make sure these models exist there:"
        echo "      ollama pull $PAS_TEXT_MODEL"
        echo "      ollama pull $PAS_VISION_MODEL"
        return 0
    }

    step_header "Downloading the AI models"
    dc up -d ollama
    local tries=0
    until dc exec -T ollama ollama list >/dev/null 2>&1; do
        tries=$(( tries + 1 )); (( tries > 30 )) && die "Ollama did not start. Check: docker compose logs ollama"
        sleep 2
    done

    local have m
    have=$(dc exec -T ollama ollama list 2>/dev/null | awk 'NR>1{print $1}')
    for m in "$PAS_TEXT_MODEL" "$PAS_VISION_MODEL"; do
        [[ -z $m ]] && continue
        if contains_line "$have" "$m"; then
            print_success "Model $m is already downloaded"
            continue
        fi
        print_step "Downloading $m — this is several GB and can take 10-30 minutes."
        if dc exec -T ollama ollama pull "$m"; then
            print_success "Model $m ready"
        else
            print_error "Could not download $m."
            echo "  Try by hand:  docker compose exec ollama ollama pull $m"
            echo "  The rest of the stack still works; AI calls will fail until the model exists."
        fi
    done
}

start_all() {
    step_header "Starting everything"
    dc up -d --remove-orphans
    sleep 5
    dc ps
}

verify() {
    step_header "Checking it actually works"
    local ok=1

    if dc exec -T webserver curl -fsS --max-time 5 http://localhost:8000 >/dev/null 2>&1; then
        print_success "Paperless-ngx answers on its own port"

        # Ask the database whether the password in .env is actually the login,
        # instead of printing it and hoping. PAS_PW_DIFFERS is NOT a failure --
        # it means the user changed their own password, which is exactly what
        # they should do after seeing it on screen -- so `ok` is left alone.
        PAS_PW_STATE=$(pw_probe)
        case $PAS_PW_STATE in
            PAS_PW_MATCH)
                print_success "Admin '$PAS_ADMIN_USER' can log in with the password in .env"
                ;;
            PAS_PW_DIFFERS)
                print_info "Admin '$PAS_ADMIN_USER' uses a password you set yourself — .env is out of date."
                echo "      Nothing was changed. Your own password is still the login."
                ;;
            PAS_PW_NOUSER)
                # Paperless-ngx only creates the superuser from the environment
                # on a FIRST boot into an empty database, so this means that
                # boot did not happen here. Printing the .env password would be
                # pointing at an account that does not exist.
                print_error "There is no user called '$PAS_ADMIN_USER' in the database."
                echo "      Look for it:  docker compose logs webserver | grep -i superuser"
                echo "      Create it by hand:"
                echo "      docker compose exec webserver python3 /usr/src/paperless/src/manage.py createsuperuser"
                ok=0
                ;;
            *)
                print_warning "Could not check the admin password against the database."
                ;;
        esac
    else
        print_error "Paperless-ngx is not answering"; ok=0
    fi

    # The OCR language is the whole point, and a missing language pack does NOT
    # stop the container -- it logs one line and carries on. So check for real
    # that every language we asked for is actually installed.
    local have_langs missing=""
    have_langs=$(dc exec -T webserver tesseract --list-langs 2>/dev/null | tail -n +2 || true)
    local want
    for want in ${PAS_OCR_LANGUAGE//+/ }; do
        contains_line "$have_langs" "$want" || missing+=" $want"
    done
    if [[ -z $missing ]]; then
        print_success "OCR languages installed and usable: $PAS_OCR_LANGUAGE"
    else
        print_error "OCR language(s) MISSING inside the container:$missing"
        echo "      Documents will fail to OCR. Almost always no internet at container boot."
        echo "      Fix the connection and run:  docker compose up -d --force-recreate webserver"
        ok=0
    fi

    if [[ $PAS_AI_MODE != none ]]; then
        local gpt_running; gpt_running=$(dc ps --status running --services 2>/dev/null || true)
        if contains_line "$gpt_running" 'paperless-gpt'; then
            print_success "Paperless-GPT container is running"
        else
            print_error "Paperless-GPT is not running — check: docker compose logs paperless-gpt"; ok=0
        fi

        # paperless-gpt creates its trigger tags shortly AFTER it starts, so this
        # has to wait for them. Checking once reported only the two tags that
        # happened to exist in that first second, which looked like a failure.
        local want_tags=(paperless-gpt paperless-gpt-auto paperless-gpt-ocr-auto paperless-gpt-failed)
        local tags="" t waited=0 missing_tags
        while (( waited < 60 )); do
            tags=$(api_tag_names)
            missing_tags=""
            for t in "${want_tags[@]}"; do
                contains_line "$tags" "$t" || missing_tags+=" $t"
            done
            [[ -z $missing_tags ]] && break
            sleep 5; waited=$(( waited + 5 ))
        done
        if [[ -z $missing_tags ]]; then
            print_success "All four AI trigger tags exist in Paperless-ngx:"
            for t in "${want_tags[@]}"; do echo "      • $t"; done
        else
            print_warning "These AI trigger tags have not appeared yet:$missing_tags"
            echo "      paperless-gpt creates them on startup. Check: docker compose logs paperless-gpt"
            echo "      A wrong API token is the usual cause — re-run ./install.sh to recreate it."
        fi
    fi

    (( ok )) || die "Application verification failed; installation is not complete."
    auth_verify
}


summary() { auth_summary; }

################################################################################
# install
################################################################################

cmd_install() {
    banner
    local reconfigure=0
    if [[ -f $ENV_FILE ]]; then
        load_env
        print_info "This looks like an existing install (./.env is already here)."
        if (( NONINTERACTIVE )); then
            print_info "Non-interactive: keeping the saved settings."
        else
            local keep=Y
            read -r -p "${CYAN}Keep all the previous answers and just re-apply them? [Y/n]: ${NC}" keep || true
            if [[ ${keep:-Y} =~ ^[Nn] ]]; then
                reconfigure=1
                print_info "OK — I will ask again, with your old answers as the defaults."
            else
                NONINTERACTIVE=1
                print_success "Keeping your settings. Re-running is safe: nothing is deleted."
            fi
        fi
    fi

    precheck
    # Snapshot existing data before changing routing, secrets or identity configuration.
    if [[ -f $COMPOSE_FILE ]] && docker volume inspect "${COMPOSE_PROJECT}_pgdata" >/dev/null 2>&1; then
        cmd_backup
    fi
    ask_config
    write_env
    auth_prepare
    write_compose
    write_prompts
    pull_images
    auth_start
    auth_provision
    start_core
    auth_link_admin
    fetch_api_token
    create_trigger_tags
    pull_models
    start_all
    verify
    (( reconfigure )) && NONINTERACTIVE=0
    summary
}

################################################################################
# status
################################################################################

cmd_status() {
    require_installed
    print_header "Status"
    dc ps
    echo
    print_step "Health checks"
    if dc exec -T webserver curl -fsS --max-time 5 http://localhost:8000 >/dev/null 2>&1; then
        print_success "Paperless-ngx: answering"
        # Same question verify() asks, so `status` does not point at .env for a
        # password that stopped being the login.
        case "$(pw_probe)" in
            PAS_PW_MATCH)   print_success "Admin password: the one in .env works" ;;
            PAS_PW_DIFFERS) print_info    "Admin password: you changed it yourself — .env is out of date" ;;
            PAS_PW_NOUSER)  print_error   "Admin password: there is no '$PAS_ADMIN_USER' user" ;;
        esac
    else
        print_error "Paperless-ngx: NOT answering"
    fi
    if [[ ${PAS_AI_MODE:-none} != none ]]; then
        local running; running=$(dc ps --status running --services 2>/dev/null || true)
        if contains_line "$running" 'paperless-gpt'; then
            print_success "Paperless-GPT: running"
        else
            print_error "Paperless-GPT: not running"
        fi
    fi
    if [[ ${PAS_OLLAMA_MODE:-none} == container ]]; then
        echo
        print_step "Models on this machine"
        dc exec -T ollama ollama list 2>/dev/null || print_warning "Ollama is not answering."
        # A model that does not fit in VRAM silently falls back to the CPU.
        if [[ ${PAS_GPU:-no} == yes ]]; then
            local psjson
            psjson=$(dc exec -T ollama sh -c 'command -v curl >/dev/null && curl -fsS http://localhost:11434/api/ps' 2>/dev/null || true)
            contains "$psjson" 'size_vram' \
                && print_info "Tip: if size_vram is smaller than size, part of the model is on the CPU."
        fi
    fi
    echo
    print_step "Disk used by your documents and database"
    local v
    for v in data media pgdata; do
        local vol="${COMPOSE_PROJECT}_${v}" sz=""
        # Guard first: `docker run -v name:/v` silently CREATES a missing volume,
        # so an unguarded size check litters the host with empty volumes.
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            sz=$(docker run --rm -v "${vol}:/v" docker.io/library/alpine:3.23.3 du -sh /v 2>/dev/null | awk '{print $1}')
        else
            sz="not created yet"
        fi
        printf '  %-10s %s\n' "$v" "${sz:-?}"
    done
    echo
    if [[ ${PAS_AUTH_ENABLED:-no} == yes ]]; then
        python3 lib/auth_config.py urls
        python3 lib/auth_verify.py
    else
        print_warning "Legacy installation: run ./install.sh to migrate to HTTPS and Authentik."
    fi

}

################################################################################
# update
################################################################################

cmd_update() {
    require_installed
    print_header "Update"
    echo "Image versions are pinned in .env, so this pulls exactly these tags:"
    printf '  paperless-ngx %s | paperless-gpt %s | ollama %s | postgres %s\n' \
        "$PAS_V_NGX" "$PAS_V_GPT" "${PAS_V_OLLAMA:-n/a}" "$PAS_V_POSTGRES"
    echo "To move to a newer release, change the PAS_V_* value in .env and run this again."
    echo
    print_step "Taking a safety backup of the database first..."
    cmd_backup
    auth_prepare
    write_compose
    print_step "Pulling images..."
    dc pull
    print_step "Restarting..."
    dc up -d --remove-orphans
    sleep 5
    dc ps
    auth_start
    auth_provision
    auth_link_admin
    verify
    print_success "Update finished and verified"
    print_info "If something broke: ./install.sh restore backups/<newest file>"
}

################################################################################
# backup / restore
################################################################################

# Row count of one table, or "" if the query failed (table or database missing).
db_count() {
    local n
    n=$(dc exec -T db psql -tAq -U paperless -d paperless \
            -c "SELECT count(*) FROM $1;" 2>/dev/null | tr -dc '0-9' || true)
    printf '%s' "$n"
}

# Dump the live database to a .sql.gz. Returns non-zero (and leaves no file)
# if pg_dump failed or produced nothing.
dump_db_to() {
    local f=$1
    mkdir -p "$(dirname "$f")"
    if ! { dc exec -T db pg_dump -U paperless -d paperless | gzip > "$f"; } 2>/dev/null; then
        rm -f "$f"; return 1
    fi
    [[ -s $f ]] || { rm -f "$f"; return 1; }
    gzip -t "$f" || return 1
    local tail; tail=$(gzip -dc "$f" | tail -20)
    contains "$tail" 'PostgreSQL database dump complete' || return 1
    chmod 600 "$f"
}

backup_db_only() {
    local f
    f="$BACKUP_DIR/db-$(date +%Y%m%d-%H%M%S).sql.gz"
    dump_db_to "$f" || return 1
    print_success "Database backup: $f"
}

cmd_backup() {
    require_installed
    print_header "Backup"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    auth_quiesce
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    local work; work=$(mktemp -d "$BACKUP_DIR/.work-XXXXXX")
    local out="$BACKUP_DIR/paperless-ar-backup-${stamp}.tar.gz"

    print_step "1/4 Database..."
    # The dump is a pipeline, so it has to be guarded explicitly: a bare
    # `pg_dump | gzip` aborts through the ERR trap and the friendly message
    # below is never reached.
    local docs; docs=$(db_count documents_document)
    if ! dump_db_to "$work/db.sql.gz"; then
        rm -rf "$work"
        die "The database dump failed or came out empty. Is the db container running?  ./install.sh status"
    fi
    print_success "Database dumped ($(du -h "$work/db.sql.gz" | cut -f1), ${docs:-?} documents)"

    print_step "2/4 Your documents (originals, archive PDFs, thumbnails)..."
    local v
    for v in media data; do
        docker run --rm -v "${COMPOSE_PROJECT}_${v}:/src:ro" -v "$work:/dst" \
            docker.io/library/alpine:3.23.3 tar czf "/dst/${v}.tar.gz" -C /src . \
            || { rm -rf "$work"; die "Could not archive the '$v' volume."; }
        print_success "${v}.tar.gz ($(du -h "$work/${v}.tar.gz" | cut -f1))"
    done

    print_step "3/4 Prompts, config and settings..."
    local -a extras=() item
    for item in prompts config db export compose.yaml .env INSTALLATION_INFO.txt auth lib PAPERLESS-LOCAL-CA.crt; do
        [[ -e "$SCRIPT_DIR/$item" ]] && extras+=("$item")
    done
    tar czf "$work/files.tar.gz" -C "$SCRIPT_DIR" "${extras[@]}"
    print_success "files.tar.gz ($(du -h "$work/files.tar.gz" | cut -f1))"

    auth_backup "$work"
    print_step "4/4 Packing..."
    # documents= is load-bearing: restore compares it with what actually landed
    # in the database, which is how a half-applied dump gets caught.
    printf 'paperless-arabic-stack backup\ncreated=%s\ninstaller=%s\npaperless_ngx=%s\npaperless_gpt=%s\npostgres=%s\ndocuments=%s\n' \
        "$(date -Iseconds)" "$SCRIPT_VERSION" "$PAS_V_NGX" "${PAS_V_GPT:-none}" "$PAS_V_POSTGRES" "${docs:-unknown}" > "$work/MANIFEST"
    tar czf "$out" -C "$work" .
    tar tzf "$out" >/dev/null || die "Backup archive verification failed."
    chmod 600 "$out"
    rm -rf "$work"

    auth_resume
    print_success "Backup ready: $out  ($(du -h "$out" | cut -f1))"
    echo
    print_warning "This archive contains .env, which contains ALL your passwords."
    echo "  Keep it somewhere private. Copy it off this machine — a backup that only"
    echo "  lives on the same server is not a backup."
    echo
    print_info "Restore it with:  ./install.sh restore $out"
}

cmd_restore() {
    local src=${1:-}
    [[ -n $src ]] || die "Usage: ./install.sh restore <backup file>"
    [[ -f $src ]] || die "No such file: $src"
    require_installed

    print_header "Restore"
    print_warning "This REPLACES the current database and all documents with the backup."
    echo "  Backup file: $src"
    tar xzf "$src" -O ./MANIFEST 2>/dev/null | sed 's/^/    /' || true
    echo
    if ! (( NONINTERACTIVE )); then
        local ans=""
        read -r -p "${CYAN}Type ${BOLD}restore${NC}${CYAN} to confirm: ${NC}" ans || true
        [[ $ans == restore ]] || { print_info "Cancelled. Nothing was changed."; exit 0; }
    fi

    local work; work=$(mktemp -d)
    python3 lib/backup_check.py "$src" "$work" || { rm -rf "$work"; die "Could not read the backup archive."; }
    [[ -f $work/db.sql.gz ]] || { rm -rf "$work"; die "There is no database dump (db.sql.gz) inside that archive."; }

    # Everything below is checked BEFORE the live database is dropped. Restore is
    # destructive, so an unusable archive has to be caught while the current
    # install is still intact.
    print_step "Checking the backup file is complete..."
    gunzip -t "$work/db.sql.gz" 2>/dev/null \
        || { rm -rf "$work"; die "The database dump inside that archive is damaged (gzip check failed). Nothing was changed."; }
    # pg_dump 18 writes its end marker, then a "\unrestrict <token>" line, then
    # possibly blank lines -- the marker is 5 lines from the end on this version.
    # The window is deliberately wide: rejecting a GOOD backup because a future
    # pg_dump added two trailing lines would be far worse than the bug this
    # check exists to catch.
    local dump_tail; dump_tail=$(gunzip -c "$work/db.sql.gz" | tail -20 || true)
    if ! contains "$dump_tail" 'PostgreSQL database dump complete'; then
        rm -rf "$work"
        die "That dump is truncated — it has no end marker. The backup is incomplete. Nothing was changed."
    fi
    local want_docs; want_docs=$(sed -n 's/^documents=//p' "$work/MANIFEST" 2>/dev/null | tr -dc '0-9' || true)
    print_success "Backup file is complete${want_docs:+ (${want_docs} documents in it)}"

    auth_restore_preflight "$work"
    print_step "Stopping the applications (the database stays up)..."
    dc stop webserver paperless-gpt 2>/dev/null || true

    # A safety dump of what is about to be destroyed. Without it a bad restore
    # leaves nothing at all to go back to.
    local safety=""
    if (( SAFETY_DUMP )); then
        print_step "Saving the CURRENT database first, in case this restore goes wrong..."
        safety="$BACKUP_DIR/pre-restore-$(date +%Y%m%d-%H%M%S).sql.gz"
        if dump_db_to "$safety"; then
            print_success "Safety dump: $safety"
        else
            safety=""
            print_error "Could not dump the current database. The db container is probably not running."
            echo "  Start it first:  docker compose up -d db      (then run restore again)"
            echo "  Or skip this safety net on purpose:  ./install.sh restore $src --no-safety-dump"
            rm -rf "$work"
            die "Stopping before anything is deleted."
        fi
    else
        print_warning "--no-safety-dump: the current database will not be saved first."
    fi

    print_step "Restoring the database..."
    # WITH (FORCE) kicks off any session still holding the database open; without
    # it the DROP blocks forever behind a worker that has not noticed the stop.
    dc exec -T db psql -q -U paperless -d postgres \
        -c 'DROP DATABASE IF EXISTS paperless WITH (FORCE);' >/dev/null
    dc exec -T db psql -q -U paperless -d postgres \
        -c 'CREATE DATABASE paperless OWNER paperless;' >/dev/null

    # -v ON_ERROR_STOP=1 is the whole point of this block. Without it psql
    # prints each failed statement, carries on, and still exits 0 -- so a
    # truncated dump restored an EMPTY database and this script said
    # "✓ Database restored". Measured: psql exits 0, psql -v ON_ERROR_STOP=1
    # exits 3 on the same broken input.
    local failed=""
    if ! gunzip -c "$work/db.sql.gz" \
         | dc_in exec -T db psql -q -v ON_ERROR_STOP=1 -U paperless -d paperless \
             >"$work/restore.log" 2>&1; then
        failed="psql stopped on an error while loading the dump"
    fi

    # Belt and braces: even a dump that loads without an error must end up with
    # a usable database in it.
    local got_docs="" got_users=""
    if [[ -z $failed ]]; then
        got_users=$(db_count auth_user)
        got_docs=$(db_count documents_document)
        if [[ -z $got_users || -z $got_docs ]]; then
            failed="the restored database has no Paperless tables in it"
        elif (( got_users == 0 )); then
            failed="the restored database has no users in it"
        elif [[ -n $want_docs && $got_docs != "$want_docs" ]]; then
            failed="the backup holds $want_docs documents but only $got_docs were restored"
        fi
    fi

    if [[ -n $failed ]]; then
        echo
        print_error "The restore FAILED: $failed."
        # Only the ERROR: lines go on screen. psql also prints a CONTEXT: line
        # that quotes the WHOLE offending row, and when the dump is broken
        # inside the auth_user table that row contains the admin's password
        # hash -- it was being printed to the terminal. ERROR: lines are
        # redacted too, because a bad column value can be credential material.
        local shown
        shown=$(grep -E 'ERROR:' "$work/restore.log" 2>/dev/null | redact_secrets | tail -n 8 || true)
        if [[ -n $shown ]]; then
            echo "  What PostgreSQL complained about:"
            sed 's/^/      /' <<<"$shown"
        fi
        echo
        if [[ -n $safety ]]; then
            print_step "Putting your previous database back from the safety dump..."
            dc exec -T db psql -q -U paperless -d postgres \
                -c 'DROP DATABASE IF EXISTS paperless WITH (FORCE);' >/dev/null
            dc exec -T db psql -q -U paperless -d postgres \
                -c 'CREATE DATABASE paperless OWNER paperless;' >/dev/null
            if gunzip -c "$safety" \
                 | dc_in exec -T db psql -q -v ON_ERROR_STOP=1 -U paperless -d paperless >/dev/null 2>&1; then
                print_success "Your previous database is back, and your documents were never touched."
            else
                print_error "The roll-back failed too. Your old database is still in this file:"
                echo "      $safety"
            fi
        else
            print_warning "There was no safety dump, so the old database is gone. Use another backup."
        fi
        dc up -d >/dev/null 2>&1 || true
        # 600, like everything else in backups/: this file holds the full psql
        # output, which can contain rows out of auth_user and authtoken_token.
        local keep; keep="$BACKUP_DIR/failed-restore-$(date +%Y%m%d-%H%M%S).log"
        if ( umask 077 && cp -f "$work/restore.log" "$keep" ) 2>/dev/null; then
            chmod 600 "$keep" 2>/dev/null || true
            print_info "Full error log (keep it private, it can quote database rows): $keep"
        fi
        rm -rf "$work"
        # Rotate before dying: this is the path that generates the log files,
        # so it is the path that most needs to not pile them up. $safety and
        # $keep are this run's, and are protected.
        prune_restore_leftovers "$safety" "$keep"
        die "Stopped on purpose. Your documents and files were left alone."
    fi

    print_success "Database restored (${got_docs} documents, ${got_users} users) — checked, not assumed"

    auth_restore "$work"
    print_step "Restoring your documents..."
    local v
    for v in media data; do
        [[ -f "$work/${v}.tar.gz" ]] || continue
        docker run --rm -v "${COMPOSE_PROJECT}_${v}:/dst" -v "$work:/src:ro" \
            docker.io/library/alpine:3.23.3 sh -c "rm -rf /dst/* /dst/.[!.]* 2>/dev/null; tar xzf /src/${v}.tar.gz -C /dst"
        print_success "${v} restored"
    done

    print_step "Restoring prompts and config..."
    [[ -f "$work/files.tar.gz" ]] && tar xzf "$work/files.tar.gz" -C "$SCRIPT_DIR" --skip-old-files 2>/dev/null || true
    print_info "Existing files were kept. Delete a file first if you want the backup's version."

    rm -rf "$work"
    print_step "Starting back up..."
    dc up -d
    reconcile_identity
    sleep 5
    dc ps
    auth_start
    auth_provision
    auth_link_admin
    verify
    print_success "Restore finished. Open your archive and check a document opens."
    if [[ -n $safety ]]; then
        print_info "The database you replaced is still saved here, delete it when you are happy:"
        echo "      $safety"
    fi
    prune_restore_leftovers "$safety"
}

# Keep only the newest $PAS_BACKUP_KEEP of the files restore leaves behind by
# itself, and delete nothing else.
#
# Scope is the whole point here. backups/ holds four kinds of file and only two
# of them are ours to delete:
#   KEPT ALWAYS  db-*.sql.gz, paperless-ar-backup-*.tar.gz
#                -- the user ran a command to make these. Never touched.
#   ROTATED      pre-restore-*.sql.gz, failed-restore-*.log
#                -- side effects of a restore the user never asked for. These
#                   are what pile up: every drill leaves one of each.
# The two patterns rotate independently, so a run of failed restores cannot
# push out the safety dumps. The file the current run just wrote is passed in
# as $2 and is never a candidate, however small PAS_BACKUP_KEEP is.
#
# Timestamped -%Y%m%d-%H%M%S names sort lexically in time order, so `sort`
# is the age ordering -- no mtime parsing, and no `ls` output to split.
prune_backups() {
    local pattern=$1 just_written=${2:-} keep=${PAS_BACKUP_KEEP:-5}
    [[ $keep =~ ^[0-9]+$ ]] || return 0
    (( keep == 0 )) && return 0          # 0 disables rotation entirely

    local -a found=()
    local f
    # Globs, not `find`/`ls`: a literal unmatched glob is the only case to skip.
    for f in "$BACKUP_DIR"/$pattern; do
        [[ -f $f ]] || continue
        [[ -n $just_written && $f == "$just_written" ]] && continue
        found+=("$f")
    done
    (( ${#found[@]} > keep )) || return 0

    local -a sorted=()
    mapfile -t sorted < <(printf '%s\n' "${found[@]}" | sort)
    local n_del=$(( ${#sorted[@]} - keep ))
    local deleted=0
    for f in "${sorted[@]:0:$n_del}"; do
        rm -f -- "$f" 2>/dev/null && deleted=$(( deleted + 1 ))
    done
    (( deleted )) && print_info "Removed $deleted old $pattern (kept the newest $keep)."
    return 0
}

# Both restore byproducts, after the run that created them is finished.
prune_restore_leftovers() {
    prune_backups 'pre-restore-*.sql.gz'   "${1:-}"
    prune_backups 'failed-restore-*.log'   "${2:-}"
}

# Does the password in .env actually log in? Prints exactly one of
# PAS_PW_MATCH / PAS_PW_DIFFERS / PAS_PW_NOUSER, or nothing if it could not ask.
#
# The password goes in through the environment, never on the command line or
# inside the python source -- a password the user typed can contain quotes.
# Captured, not piped into `grep -q`: a quitting grep SIGPIPEs the exec and
# pipefail then reports 141 for a run that actually worked. For the same reason
# there is no `head -1`/`grep -m1` here.
pw_probe() {
    dc exec -T -e PAS_PW="$PAS_ADMIN_PASSWORD" -e PAS_USER="$PAS_ADMIN_USER" \
        webserver python3 /usr/src/paperless/src/manage.py shell -c '
import os
from django.contrib.auth import get_user_model
u = get_user_model().objects.filter(username=os.environ["PAS_USER"]).first()
if u is None:
    print("PAS_PW_NOUSER")
elif u.check_password(os.environ["PAS_PW"]):
    print("PAS_PW_MATCH")
else:
    print("PAS_PW_DIFFERS")
' 2>/dev/null | grep -oE 'PAS_PW_(MATCH|DIFFERS|NOUSER)' || true
}

# Writes .env's password into the database. Only ever called with the user's
# explicit say-so (--reset-admin-password, the prompt, or a missing user).
set_admin_pw() {
    local out
    out=$(dc exec -T -e PAS_PW="$PAS_ADMIN_PASSWORD" -e PAS_USER="$PAS_ADMIN_USER" \
            webserver python3 /usr/src/paperless/src/manage.py shell -c '
import os
from django.contrib.auth import get_user_model
U = get_user_model()
u, _ = U.objects.get_or_create(username=os.environ["PAS_USER"])
u.is_superuser = True
u.is_staff = True
u.set_password(os.environ["PAS_PW"])
u.save()
print("PAS_ADMIN_OK")
' 2>/dev/null || true)
    contains "$out" 'PAS_ADMIN_OK' || return 1
    # Checked, not assumed.
    [[ $(pw_probe) == PAS_PW_MATCH ]]
}

# A restored database carries the admin password and the API token from the
# machine the backup came from, while .env still holds this machine's. Restoring
# onto a fresh install (the actual disaster-recovery path) therefore printed an
# admin password that did not work, and left paperless-gpt holding a dead token.
#
# The two are NOT symmetric, and the first version of this got the password
# wrong by treating them the same way:
#   * API token: .env <- database. The database owns the token; .env only holds
#     a copy for paperless-gpt to read. Copying it back destroys nothing.
#   * Admin password: the database owns it too, and it is the user's OWN
#     password -- the one they changed after the install and which their backup
#     correctly contains. Writing .env's password over it silently threw that
#     away and then reported the login was fine. So: check it, say what is
#     true, and only overwrite when the user asks.
reconcile_identity() {
    print_step "Checking the admin login and the API token..."

    local tries=0
    until dc exec -T webserver curl -fsS --max-time 3 http://localhost:8000 >/dev/null 2>&1; do
        tries=$(( tries + 1 ))
        if (( tries >= 60 )); then
            print_warning "Paperless-ngx has not come back up yet, so nothing was checked."
            echo "      When it is up, run ./install.sh again."
            return 0
        fi
        sleep 5
    done

    case "$(pw_probe)" in
        PAS_PW_MATCH)
            print_success "Admin '$PAS_ADMIN_USER' can log in with the password in .env"
            ;;
        PAS_PW_NOUSER)
            print_warning "The backup has no user called '$PAS_ADMIN_USER'."
            if set_admin_pw; then
                print_success "Created admin '$PAS_ADMIN_USER' with the password in .env"
            else
                print_warning "Could not create it. Log in with an admin account from the backup."
            fi
            ;;
        PAS_PW_DIFFERS)
            echo
            print_warning "Your admin password is now the one from the BACKUP, not the one in .env."
            echo "  That is almost always what you want: the backup holds the password you"
            echo "  set yourself. Log in with the password you used when you took that backup."
            echo "  ${BOLD}The password printed in .env is out of date — it is not your login.${NC}"
            echo
            local do_reset=$RESET_ADMIN_PW
            if ! (( do_reset )) && ! (( NONINTERACTIVE )); then
                echo "  Lost that password (restoring onto a new machine, for example)?"
                local ans=""
                read -r -p "${CYAN}Overwrite it with the password from .env? [y/${BOLD}N${NC}${CYAN}]: ${NC}" ans || true
                case ${ans,,} in y|yes) do_reset=1 ;; esac
            fi
            if (( do_reset )); then
                if set_admin_pw; then
                    print_success "Admin '$PAS_ADMIN_USER' now uses the password in .env — checked, not assumed"
                else
                    print_warning "Could not reset it. The backup's own password still works."
                fi
            else
                print_info "Password left exactly as the backup had it. Nothing was changed."
                echo "      To overwrite it later:  ./install.sh restore <file> --reset-admin-password"
            fi
            ;;
        *)
            print_warning "Could not check the admin password. The backup's own password should still work."
            ;;
    esac

    if [[ $PAS_AI_MODE != none ]]; then
        local token
        token=$(dc exec -T webserver python3 /usr/src/paperless/src/manage.py shell -c '
from rest_framework.authtoken.models import Token
from django.contrib.auth import get_user_model
u = get_user_model().objects.filter(is_superuser=True).order_by("id").first()
if u is not None:
    t, _ = Token.objects.get_or_create(user=u)
    print("PAS_TOKEN=%s" % t.key)
' 2>/dev/null | grep -oE 'PAS_TOKEN=[0-9a-f]{40}' | cut -d= -f2 || true)
        if [[ -n $token ]]; then
            if [[ $token != "${PAPERLESS_API_TOKEN:-}" ]]; then
                env_set PAPERLESS_API_TOKEN "$token"
                load_env
                dc up -d paperless-gpt >/dev/null 2>&1 || true
                print_success "API token taken from the restored database and given to Paperless-GPT"
            else
                print_success "API token still matches"
            fi
        else
            print_warning "Could not read the API token back. Run ./install.sh to recreate it."
        fi
    fi
}

################################################################################
# uninstall
################################################################################

cmd_uninstall() {
    require_installed
    print_header "Uninstall"
    echo "By default this ${BOLD}stops${NC} the stack and ${BOLD}keeps all your documents${NC}."
    echo "Your data lives in Docker volumes: ${COMPOSE_PROJECT}_data, _media, _pgdata"
    echo
    if ! (( NONINTERACTIVE )); then
        local ans=""
        read -r -p "${CYAN}Type ${BOLD}stop${NC}${CYAN} to stop the stack (anything else cancels): ${NC}" ans || true
        [[ $ans == stop ]] || { print_info "Cancelled. Nothing was changed."; exit 0; }
    fi
    dc down --remove-orphans
    print_success "Stopped. Your documents are untouched."
    echo "  Start it again any time with:  ./install.sh"
    echo

    if (( NONINTERACTIVE )); then
        print_info "Non-interactive: keeping the data volumes. Use --purge-data to delete them."
        return 0
    fi
    print_warning "Do you also want to DELETE every document, the database, and the AI models?"
    echo "  ${RED}${BOLD}This cannot be undone.${NC} Take a backup first: ./install.sh backup"
    local ans2=""
    read -r -p "${CYAN}Type ${BOLD}DELETE MY DATA${NC}${CYAN} to erase everything, or press Enter to keep it: ${NC}" ans2 || true
    if [[ $ans2 == "DELETE MY DATA" ]]; then
        dc down -v --remove-orphans
        print_success "All volumes deleted."
        echo "  The folder $SCRIPT_DIR is still here (including .env). Remove it by hand if you want."
    else
        print_success "Your data was kept."
    fi
}

################################################################################
# plumbing
################################################################################

require_installed() {
    [[ -f $ENV_FILE ]] || die "No install found here. Run ./install.sh first."
    [[ -f $COMPOSE_FILE ]] || die "compose.yaml is missing. Run ./install.sh to regenerate it."
    load_env
    : "${PAS_TARGET:?.env looks incomplete — re-run ./install.sh}"
    command_exists docker || die "Docker is not installed."
}

usage() {
    cat <<EOF
Paperless Arabic Stack — installer $SCRIPT_VERSION

  ./install.sh                 install, or re-apply an existing install
  ./install.sh status          what is running, where, and how much disk it uses
  ./install.sh update          pull the pinned images again and restart
  ./install.sh backup          DB + documents + prompts/config -> ./backups
  ./install.sh restore <file>  restore from a backup archive
  ./install.sh uninstall       stop the stack (your documents are kept)
  ./install.sh auth-recover    create a private, time-limited Authentik recovery link
  ./install.sh help            this text

Options:
  --yes, -y          do not ask anything; use .env / PAS_* environment variables
  --purge-data       with 'uninstall': also delete the data volumes (destructive)
  --no-safety-dump   with 'restore': do not save the database being replaced
  --reset-admin-password
                     with 'restore': overwrite the restored admin password with
                     the one in .env. Without this, restore keeps the password
                     the backup contains (which is your own).

Everything lives in this folder. Passwords are in ./.env (chmod 600).

'backups/' also collects two files that a restore leaves behind by itself:
pre-restore-*.sql.gz (the database it replaced) and failed-restore-*.log. Each
restore keeps the newest 5 of each and deletes older ones. Change that with
PAS_BACKUP_KEEP=<n> in .env, or PAS_BACKUP_KEEP=0 to never delete anything.
The backups you make yourself — db-*.sql.gz and paperless-ar-backup-*.tar.gz —
are never deleted, whatever PAS_BACKUP_KEEP says.
EOF
}

main() {
    if command_exists flock; then
        exec 9>"$SCRIPT_DIR/.installer.lock"
        flock -n 9 || die "Another installer operation is active in this directory."
    fi
    local cmd="" purge=0
    local -a pos=()
    # Flags are accepted in ANY position. The first version stopped scanning at
    # the first non-flag word, so `restore <file> --yes` silently dropped --yes,
    # the confirmation prompt then read nothing, and the restore "cancelled".
    while (( $# )); do
        case $1 in
            --yes|-y)     NONINTERACTIVE=1 ;;
            --purge-data) purge=1 ;;
            --no-safety-dump) SAFETY_DUMP=0 ;;
            --reset-admin-password) RESET_ADMIN_PW=1 ;;
            -h|--help)    usage; return 0 ;;
            --*)          usage; die "Unknown option: $1" ;;
            *)            if [[ -z $cmd ]]; then cmd=$1; else pos+=("$1"); fi ;;
        esac
        shift
    done
    cmd=${cmd:-install}

    case $cmd in
        install)   cmd_install ;;
        status)    cmd_status ;;
        update)    cmd_update ;;
        auth-recover) require_installed; auth_recover ;;
        backup)    cmd_backup ;;
        restore)   cmd_restore "${pos[0]:-}" ;;
        uninstall)
            if (( purge )); then
                require_installed
                print_warning "--purge-data: deleting the stack AND all data volumes."
                if ! (( NONINTERACTIVE )); then
                    local a=""; read -r -p "${CYAN}Type ${BOLD}DELETE MY DATA${NC}${CYAN} to confirm: ${NC}" a || true
                    [[ $a == "DELETE MY DATA" ]] || { print_info "Cancelled."; exit 0; }
                else
                    # --purge-data --yes cannot ask, so give the one guard left:
                    # a window to stop it. Every document, the database and the
                    # downloaded models go, and nothing brings them back.
                    print_warning "Every document, the database and the AI models will be deleted."
                    echo "  ${RED}${BOLD}This cannot be undone.${NC}  Press Ctrl-C in the next 10 seconds to stop."
                    local s
                    for s in 10 9 8 7 6 5 4 3 2 1; do printf '\r  deleting in %2d ...' "$s"; sleep 1; done
                    printf '\r                        \r'
                fi
                dc down -v --remove-orphans
                print_success "Everything removed."
            else
                cmd_uninstall
            fi ;;
        help|-h|--help) usage ;;
        *) usage; exit 1 ;;
    esac
}

source "$SCRIPT_DIR/lib/auth.sh"
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
