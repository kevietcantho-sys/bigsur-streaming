#!/usr/bin/env bash
# =============================================================================
# Remote wrapper — runs setup-srs.sh on a target box.
# Uploads setup-srs.sh + common/lib.sh, then executes remotely.
# =============================================================================
#
# Usage:
#   ./setup-srs-remote.sh [OPTIONS] <host> [host-2] ...
#
# Options:
#   -u USER       SSH user (default: root)
#   -i IDENTITY   SSH identity file
#   -p PASS       SRS_API_PASS (overrides .env / STREAM_KEYS file)
#   -h            Help
#
# SRS_API_PASS resolution order:
#   1. -p flag
#   2. SRS_API_PASS env var
#   3. SRS_API_PASS from .env
#   4. SRS_API_PASS in scripts/.STREAM_KEYS.<haproxy-host>.txt (saved by
#      setup-stream-auth-remote.sh)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/setup-srs.sh"
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

Options:
  -u USER       SSH user (default: \$SSH_USER or 'root')
  -i IDENTITY   SSH identity file
  -p PASS       SRS_API_PASS override
  -h            Help

Examples:
  $0 10.40.96.4
  $0 -p s3cret 10.40.96.4
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

while getopts "u:i:p:h" opt; do
    case $opt in
        u) SSH_USER="$OPTARG" ;;
        i) SSH_IDENTITY="$OPTARG" ;;
        p) SRS_API_PASS="$OPTARG" ;;
        h) usage ;;
        *) fail "Unknown option. Use -h." ;;
    esac
done
shift $((OPTIND - 1))

for arg in "$@"; do
    [[ "$arg" == -* ]] && fail "Flag '$arg' must come BEFORE host IPs."
done

[[ $# -lt 1 ]] && fail "Missing host."
[[ ! -f "${SETUP_SCRIPT}" ]] && fail "setup-srs.sh missing at ${SETUP_SCRIPT}"
[[ ! -f "${LIB_FILE}" ]]     && fail "common/lib.sh missing at ${LIB_FILE}"

# Try to recover SRS_API_PASS from a previously-saved STREAM_KEYS snapshot.
if [[ -z "${SRS_API_PASS:-}" ]]; then
    KEYS_MATCHES=()
    for f in "${SCRIPTS_DIR}"/.STREAM_KEYS.*.txt; do
        [[ -f "$f" ]] && KEYS_MATCHES+=("$f")
    done
    [[ ${#KEYS_MATCHES[@]} -gt 1 ]] && \
        warn "Multiple STREAM_KEYS snapshots found; using first match — pass -p <pass> to target a specific host."
    if [[ ${#KEYS_MATCHES[@]} -gt 0 ]]; then
        for f in "${KEYS_MATCHES[@]}"; do
            cand=$(grep -E '^[[:space:]]*Pass:' "$f" | head -n1 | awk '{print $2}' || true)
            if [[ -n "${cand}" ]]; then
                SRS_API_PASS="${cand}"
                info "Recovered SRS_API_PASS from $(basename "$f")"
                break
            fi
        done
    fi
fi

[[ -z "${SRS_API_PASS:-}" ]] && fail "SRS_API_PASS missing. Set via -p, .env, or run setup-stream-auth-remote.sh first."

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "${SSH_IDENTITY}" ]] && SSH_OPTS+=(-i "${SSH_IDENTITY}")
SCP_OPTS=("${SSH_OPTS[@]}")

FORWARD_VARS=(
    SRS_VPC_IP HAPROXY_VPC_IP STREAM_AUTH_VPC_IP
    SRS_API_USER SRS_API_PASS
    STREAM_AUTH_PORT SRS_VERSION
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
info "SRS API user  : ${GREEN}${SRS_API_USER:-admin}${NC}"
info "SRS API pass  : ${GREEN}(set, ${#SRS_API_PASS} chars)${NC}"

TOTAL=$#; COUNT=0; FAILED=()
REMOTE_DIR=/tmp/bigsur-srs-setup

for HOST in "$@"; do
    COUNT=$((COUNT + 1))
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  [${COUNT}/${TOTAL}] srs on ${HOST}${NC}"
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
    scp "${SCP_OPTS[@]}" "${SETUP_SCRIPT}" "${SSH_USER}@${HOST}:${REMOTE_DIR}/setup-srs.sh"
    scp "${SCP_OPTS[@]}" "${LIB_FILE}"     "${SSH_USER}@${HOST}:${REMOTE_DIR}/lib.sh"
    log "Upload done"

    info "Executing remote setup..."
    ENV_PREFIX="$(build_env_prefix)"
    SUDO=""; [[ "${SSH_USER}" != "root" ]] && SUDO="sudo -E "
    REMOTE_CMD="cd ${REMOTE_DIR} && chmod +x setup-srs.sh && ${SUDO}env ${ENV_PREFIX} bash ./setup-srs.sh"

    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "${REMOTE_CMD}"; then
        log "srs on ${HOST} SUCCESS"
    else
        warn "srs on ${HOST} FAILED"; FAILED+=("${HOST}"); continue
    fi

    info "Cleaning up ${REMOTE_DIR}..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "sudo rm -rf ${REMOTE_DIR}" || true
done

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  srs Setup Summary${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Total       : ${GREEN}${TOTAL}${NC}"
echo -e "Succeeded   : ${GREEN}$((TOTAL - ${#FAILED[@]}))${NC}"
echo -e "Failed      : ${RED}${#FAILED[@]}${NC}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""; warn "Failed hosts:"; for h in "${FAILED[@]}"; do echo "  - $h"; done; exit 1
fi

echo ""
log "srs deployed."
