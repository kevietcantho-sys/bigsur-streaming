#!/usr/bin/env bash
# =============================================================================
# Remote wrapper — runs setup-stream-auth.sh on a target box.
# Run from a LOCAL machine. SSHes to <host>, uploads:
#   - setup-stream-auth.sh
#   - common/lib.sh
#   - <repo>/streaming-auth/ (full source tree)
# Then executes setup-stream-auth.sh as root remotely.
# =============================================================================
#
# Usage:
#   ./setup-stream-auth-remote.sh [OPTIONS] <host> [host-2] ...
#
# Options:
#   -u USER          SSH user (override SSH_USER, default: root; or bootstrap'd sudoer)
#   -i IDENTITY      SSH identity file
#   -h               Help
#
# Config loaded from ../.env (relative to scripts/). Override per-host with env
# vars or flags. SSH user is either root, or a bootstrap'd user with passwordless
# sudo (see common/bootstrap-remote.sh) — the wrapper prefixes `sudo -E` to the
# remote run whenever SSH_USER isn't root.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_DIR}/../.." && pwd)"

SETUP_SCRIPT="${SCRIPT_DIR}/setup-stream-auth.sh"
LIB_FILE="${SCRIPTS_DIR}/common/lib.sh"
SRC_DIR="${REPO_ROOT}/streaming-auth"
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
  -u USER       SSH user (default: \$SSH_USER or 'root'; e.g. bootstrap'd sudoer)
  -i IDENTITY   SSH identity file
  -h            Help

Examples:
  $0 45.76.145.205
  $0 -u deploy 45.76.145.205
  $0 -u deploy -i ~/.ssh/id_ed25519 45.76.145.205
EOF
    exit 0
}

# Load .env
if [[ -f "${ENV_FILE}" ]]; then
    info "Loading config from ${ENV_FILE}"
    set -a; . "${ENV_FILE}"; set +a
elif [[ -f "${ENV_EXAMPLE}" ]]; then
    warn ".env missing — using defaults from .env.example"
    set -a; . "${ENV_EXAMPLE}"; set +a
fi

SSH_USER="${SSH_USER:-root}"
SSH_IDENTITY=""

while getopts "u:i:h" opt; do
    case $opt in
        u) SSH_USER="$OPTARG" ;;
        i) SSH_IDENTITY="$OPTARG" ;;
        h) usage ;;
        *) fail "Unknown option. Use -h for help." ;;
    esac
done
shift $((OPTIND - 1))

for arg in "$@"; do
    [[ "$arg" == -* ]] && fail "Flag '$arg' must come BEFORE host IPs."
done

[[ $# -lt 1 ]] && fail "Missing host. Usage: $0 [OPTIONS] <host> [...]"
[[ ! -f "${SETUP_SCRIPT}" ]] && fail "setup-stream-auth.sh missing at ${SETUP_SCRIPT}"
[[ ! -f "${LIB_FILE}"     ]] && fail "common/lib.sh missing at ${LIB_FILE}"
[[ ! -d "${SRC_DIR}"      ]] && fail "streaming-auth source missing at ${SRC_DIR}"
[[ ! -f "${SRC_DIR}/package.json" ]] && fail "${SRC_DIR}/package.json missing"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "${SSH_IDENTITY}" ]] && SSH_OPTS+=(-i "${SSH_IDENTITY}")
SCP_OPTS=("${SSH_OPTS[@]}")
RSYNC_SSH="ssh ${SSH_OPTS[*]}"

# Env vars forwarded to the remote run. Keep this list explicit so a stale
# operator env doesn't leak into the box.
FORWARD_VARS=(
    HAPROXY_VPC_IP SRS_VPC_IP HAPROXY_PUBLIC_IP
    STREAM_AUTH_VPC_IP STREAM_AUTH_PORT
    PUBLISH_HOST PUBLISH_APP PLAYBACK_ORIGIN_HOST LETSENCRYPT_EMAIL
    SRS_API_USER SRS_API_PASS
)

build_env_prefix() {
    local out=""
    local v val
    for v in "${FORWARD_VARS[@]}"; do
        val="${!v:-}"
        # Always emit so the remote can see "explicitly empty" vs "unset".
        # Single-quote-escape: ' → '\''
        local esc="${val//\'/\'\\\'\'}"
        out+=" ${v}='${esc}'"
    done
    printf '%s' "${out# }"
}

info "SSH user      : ${GREEN}${SSH_USER}${NC}"
info "Source tree   : ${GREEN}${SRC_DIR}${NC}"
info "Hosts         : ${GREEN}$*${NC}"

TOTAL=$#; COUNT=0; FAILED=()
REMOTE_DIR="/tmp/bigsur-stream-auth-setup"

for HOST in "$@"; do
    COUNT=$((COUNT + 1))
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  [${COUNT}/${TOTAL}] stream-auth on ${HOST}${NC}"
    echo -e "${BLUE}============================================${NC}"

    info "Testing SSH..."
    if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_USER}@${HOST}" "echo OK" &>/dev/null; then
        warn "SSH to ${SSH_USER}@${HOST} failed — skipping"
        FAILED+=("${HOST}"); continue
    fi
    log "SSH OK"

    info "Preparing remote ${REMOTE_DIR}..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" \
        "sudo rm -rf ${REMOTE_DIR} && sudo mkdir -p ${REMOTE_DIR} && sudo chown ${SSH_USER}: ${REMOTE_DIR}"

    info "Uploading setup script + lib.sh..."
    scp "${SCP_OPTS[@]}" "${SETUP_SCRIPT}" "${SSH_USER}@${HOST}:${REMOTE_DIR}/setup-stream-auth.sh"
    scp "${SCP_OPTS[@]}" "${LIB_FILE}"     "${SSH_USER}@${HOST}:${REMOTE_DIR}/lib.sh"

    info "Rsyncing streaming-auth/ source..."
    rsync -az --delete \
        -e "${RSYNC_SSH}" \
        --exclude 'node_modules/' \
        --exclude 'dist/' \
        --exclude 'coverage/' \
        --exclude '.env' \
        --exclude '.env.*' \
        --exclude '*.log' \
        "${SRC_DIR}/" "${SSH_USER}@${HOST}:${REMOTE_DIR}/streaming-auth/"
    log "Upload done"

    info "Executing remote setup..."
    ENV_PREFIX="$(build_env_prefix)"
    SUDO=""
    [[ "${SSH_USER}" != "root" ]] && SUDO="sudo -E "
    REMOTE_CMD="cd ${REMOTE_DIR} && chmod +x setup-stream-auth.sh && ${SUDO}env ${ENV_PREFIX} bash ./setup-stream-auth.sh"

    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "${REMOTE_CMD}"; then
        log "stream-auth on ${HOST} SUCCESS"
    else
        warn "stream-auth on ${HOST} FAILED"
        FAILED+=("${HOST}"); continue
    fi

    info "Cleaning up ${REMOTE_DIR}..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "sudo rm -rf ${REMOTE_DIR}" || true

    # Pull STREAM_KEYS.txt back so the operator can pass SRS_API_PASS to
    # setup-srs-remote.sh. The setup script writes it into the invoking user's
    # home (== ${SSH_USER}, since `sudo -E` sets SUDO_USER to the SSH user), so
    # a relative scp path — which SFTP resolves to ${SSH_USER}'s home — reads it
    # without sudo for both root (~ = /root) and the bootstrap'd sudo user.
    LOCAL_KEYS="${SCRIPTS_DIR}/.STREAM_KEYS.${HOST}.txt"
    if scp "${SCP_OPTS[@]}" "${SSH_USER}@${HOST}:STREAM_KEYS.txt" "${LOCAL_KEYS}" 2>/dev/null \
            && [[ -s "${LOCAL_KEYS}" ]]; then
        chmod 600 "${LOCAL_KEYS}"
        info "Saved credentials snapshot at ${LOCAL_KEYS} (chmod 600)"
    else
        rm -f "${LOCAL_KEYS}"
        warn "Could not pull STREAM_KEYS.txt from ${SSH_USER}@${HOST}'s home"
    fi
done

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  stream-auth Setup Summary${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Total       : ${GREEN}${TOTAL}${NC}"
echo -e "Succeeded   : ${GREEN}$((TOTAL - ${#FAILED[@]}))${NC}"
echo -e "Failed      : ${RED}${#FAILED[@]}${NC}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    warn "Failed hosts:"
    for h in "${FAILED[@]}"; do echo "  - $h"; done
    exit 1
fi

echo ""
log "stream-auth deployed."
echo ""
info "Next:"
echo "  - Run setup-haproxy-remote.sh on the same/edge box."
echo "  - Run setup-srs-remote.sh on the SRS box; pass SRS_API_PASS from STREAM_KEYS.txt."
