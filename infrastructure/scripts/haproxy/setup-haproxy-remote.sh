#!/usr/bin/env bash
# =============================================================================
# Remote wrapper — runs setup-haproxy.sh on a target box.
# Uploads setup-haproxy.sh + common/lib.sh, then executes remotely.
# Does NOT deploy stream-auth (use setup-stream-auth-remote.sh first).
# =============================================================================
#
# Usage:
#   ./setup-haproxy-remote.sh [OPTIONS] <host> [host-2] ...
#
# Options:
#   -u USER       SSH user (override SSH_USER, default: root)
#   -i IDENTITY   SSH identity file
#   -h            Help
#
# Config loaded from ../.env (relative to scripts/). Override per-host via env.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/setup-haproxy.sh"
LIB_FILE="${SCRIPTS_DIR}/common/lib.sh"
ENV_FILE="${SCRIPTS_DIR}/.env"
ENV_EXAMPLE="${SCRIPTS_DIR}/.env.example"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <host> [host-2] ...

Loads defaults from ${ENV_FILE}, override below.

Options:
  -u USER       SSH user (default: \$SSH_USER or 'root')
  -i IDENTITY   SSH identity file
  -h            Help

Examples:
  $0 45.76.145.205
  $0 -u ubuntu -i ~/.ssh/id_ed25519 45.76.145.205
EOF
    exit 0
}

if [[ -f "${ENV_FILE}" ]]; then
    info "Loading config from ${ENV_FILE}"
    set -a; . "${ENV_FILE}"; set +a
elif [[ -f "${ENV_EXAMPLE}" ]]; then
    warn ".env missing — using .env.example defaults"
    set -a; . "${ENV_EXAMPLE}"; set +a
fi

SSH_USER="${SSH_USER:-root}"
SSH_IDENTITY=""

while getopts "u:i:h" opt; do
    case $opt in
        u) SSH_USER="$OPTARG" ;;
        i) SSH_IDENTITY="$OPTARG" ;;
        h) usage ;;
        *) fail "Unknown option. Use -h." ;;
    esac
done
shift $((OPTIND - 1))

for arg in "$@"; do
    [[ "$arg" == -* ]] && fail "Flag '$arg' must come BEFORE host IPs."
done

[[ $# -lt 1 ]] && fail "Missing host."
[[ ! -f "${SETUP_SCRIPT}" ]] && fail "setup-haproxy.sh missing at ${SETUP_SCRIPT}"
[[ ! -f "${LIB_FILE}" ]]     && fail "common/lib.sh missing at ${LIB_FILE}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "${SSH_IDENTITY}" ]] && SSH_OPTS+=(-i "${SSH_IDENTITY}")
SCP_OPTS=("${SSH_OPTS[@]}")

FORWARD_VARS=(
    HAPROXY_VPC_IP SRS_VPC_IP HAPROXY_PUBLIC_IP
    PUBLISH_HOST PLAYBACK_ORIGIN_HOST
    LETSENCRYPT_EMAIL ALLOW_NO_TLS
    STREAM_AUTH_VPC_IP STREAM_AUTH_PORT
    BUNNY_EDGE_GUARD
)

build_env_prefix() {
    local out="" v val esc
    for v in "${FORWARD_VARS[@]}"; do
        val="${!v:-}"
        esc="${val//\'/\'\\\'\'}"
        out+=" ${v}='${esc}'"
    done
    printf '%s' "${out# }"
}

info "SSH user      : ${GREEN}${SSH_USER}${NC}"
info "Hosts         : ${GREEN}$*${NC}"

TOTAL=$#; COUNT=0; FAILED=()
REMOTE_DIR=/tmp/bigsur-haproxy-setup

for HOST in "$@"; do
    COUNT=$((COUNT + 1))
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  [${COUNT}/${TOTAL}] haproxy on ${HOST}${NC}"
    echo -e "${BLUE}============================================${NC}"

    info "Testing SSH..."
    if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_USER}@${HOST}" "echo OK" &>/dev/null; then
        warn "SSH failed — skipping"; FAILED+=("${HOST}"); continue
    fi
    log "SSH OK"

    info "Preparing ${REMOTE_DIR}..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" \
        "sudo rm -rf ${REMOTE_DIR} && sudo mkdir -p ${REMOTE_DIR} && sudo chown ${SSH_USER}: ${REMOTE_DIR}"

    info "Uploading setup script + lib.sh..."
    scp "${SCP_OPTS[@]}" "${SETUP_SCRIPT}" "${SSH_USER}@${HOST}:${REMOTE_DIR}/setup-haproxy.sh"
    scp "${SCP_OPTS[@]}" "${LIB_FILE}"     "${SSH_USER}@${HOST}:${REMOTE_DIR}/lib.sh"
    log "Upload done"

    info "Executing remote setup..."
    ENV_PREFIX="$(build_env_prefix)"
    SUDO=""; [[ "${SSH_USER}" != "root" ]] && SUDO="sudo -E "
    REMOTE_CMD="cd ${REMOTE_DIR} && chmod +x setup-haproxy.sh && ${SUDO}env ${ENV_PREFIX} bash ./setup-haproxy.sh"

    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "${REMOTE_CMD}"; then
        log "haproxy on ${HOST} SUCCESS"
    else
        warn "haproxy on ${HOST} FAILED"; FAILED+=("${HOST}"); continue
    fi

    info "Cleaning up ${REMOTE_DIR}..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "sudo rm -rf ${REMOTE_DIR}" || true
done

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  haproxy Setup Summary${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Total       : ${GREEN}${TOTAL}${NC}"
echo -e "Succeeded   : ${GREEN}$((TOTAL - ${#FAILED[@]}))${NC}"
echo -e "Failed      : ${RED}${#FAILED[@]}${NC}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""; warn "Failed hosts:"; for h in "${FAILED[@]}"; do echo "  - $h"; done; exit 1
fi

echo ""
log "haproxy deployed."
