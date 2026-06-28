#!/usr/bin/env bash
# =============================================================================
# Bootstrap wrapper — runs from your LOCAL machine.
# SSHes into a fresh box as root, uploads + executes bootstrap.sh, which
# creates a non-root sudo user. Run this ONCE per box BEFORE setup-*-remote.sh.
# =============================================================================
#
# Config loaded from ../.env (relative to infrastructure/scripts/), override
# per-call with flags below.
#
# Usage:
#   ./bootstrap-remote.sh [OPTIONS] <host> [host-2] ...
#
# Options:
#   -u USER        Non-root user to create (override NEW_USER)
#   -s SUBNET      VPC CIDR              (override VPC_SUBNET)
#   -b CIDR        Bastion/operator CIDR (override BASTION_CIDR)
#   -z TIMEZONE    Timezone              (override TIMEZONE)
#   -k AUTH_KEY    Tailscale auth key    (override TAILSCALE_AUTH_KEY) — enables
#                  the Tailscale step; empty/unset -> skipped.
#   -t TAGS        Tailscale tags        (override TAILSCALE_TAGS)
#                  e.g. "tag:service,tag:production"
#   -T             Skip Tailscale for this run (keeps the shared key in .env).
#   -h             Help
#
# Examples:
#   ./bootstrap-remote.sh 45.76.145.205
#   ./bootstrap-remote.sh -u deploy 10.40.96.3
#   ./bootstrap-remote.sh -b 1.2.3.4/32 10.40.96.3 10.40.96.4
#   ./bootstrap-remote.sh -k tskey-auth-xxx 10.40.96.3
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bootstrap.sh"
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
  -u USER        Non-root user to create (override NEW_USER)
  -s SUBNET      VPC CIDR              (override VPC_SUBNET)
  -b CIDR        Bastion/operator CIDR (override BASTION_CIDR)
  -z TIMEZONE    Timezone             (override TIMEZONE)
  -k AUTH_KEY    Tailscale auth key   (override TAILSCALE_AUTH_KEY)
                 -> enables the Tailscale step; skipped if empty.
  -t TAGS        Tailscale tags       (override TAILSCALE_TAGS)
                 e.g. "tag:service,tag:production"
  -T             Skip Tailscale for this run (keeps the key in .env).
  -h             Help

Examples:
  $0 45.76.145.205
  $0 -u deploy 10.40.96.3
  $0 -b 1.2.3.4/32 10.40.96.3 10.40.96.4
  $0 -k tskey-auth-xxx 10.40.96.3
EOF
    exit 0
}

# =============================================================================
# LOAD .env
# =============================================================================
if [[ -f "${ENV_FILE}" ]]; then
    info "Loading config from ${ENV_FILE}"
    # shellcheck disable=SC1090
    set -a; . "${ENV_FILE}"; set +a
elif [[ -f "${ENV_EXAMPLE}" ]]; then
    warn ".env missing — using .env.example defaults"
    warn "Recommended: cp ${ENV_EXAMPLE} ${ENV_FILE} && edit"
    # shellcheck disable=SC1090
    set -a; . "${ENV_EXAMPLE}"; set +a
fi

# Defaults (when some vars are absent from .env)
NEW_USER="${NEW_USER:-ubuntu}"
VPC_SUBNET="${VPC_SUBNET:-10.40.96.0/20}"
BASTION_CIDR="${BASTION_CIDR:-}"
TIMEZONE="${TIMEZONE:-Asia/Ho_Chi_Minh}"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_TAGS="${TAILSCALE_TAGS:-}"
SKIP_TAILSCALE="${SKIP_TAILSCALE:-0}"

# =============================================================================
# PARSE ARGS (override .env)
# =============================================================================
while getopts "u:s:b:z:k:t:Th" opt; do
    case $opt in
        u) NEW_USER="$OPTARG" ;;
        s) VPC_SUBNET="$OPTARG" ;;
        b) BASTION_CIDR="$OPTARG" ;;
        z) TIMEZONE="$OPTARG" ;;
        k) TAILSCALE_AUTH_KEY="$OPTARG" ;;
        t) TAILSCALE_TAGS="$OPTARG" ;;
        T) SKIP_TAILSCALE=1 ;;
        h) usage ;;
        *) fail "Unknown option. Use -h for help." ;;
    esac
done
shift $((OPTIND - 1))

# Detect flags-after-positional (getopts stops at the first non-option).
for arg in "$@"; do
    [[ "$arg" == -* ]] && fail "Flag '$arg' must come BEFORE host IPs."
done

# =============================================================================
# CHECKS
# =============================================================================
[[ $# -lt 1 ]] && fail "Missing host. Use: $0 [OPTIONS] <host> [...]"
[[ ! -f "${BOOTSTRAP_SCRIPT}" ]] && fail "bootstrap.sh missing at ${BOOTSTRAP_SCRIPT}"

info "User         : ${GREEN}${NEW_USER}${NC}"
info "VPC subnet   : ${GREEN}${VPC_SUBNET}${NC}"
info "Bastion CIDR : ${GREEN}${BASTION_CIDR:-<empty>}${NC}"
info "Timezone     : ${GREEN}${TIMEZONE}${NC}"
if [[ "${SKIP_TAILSCALE}" == "1" ]]; then
    info "Tailscale    : ${YELLOW}skipped (-T flag)${NC}"
elif [[ -n "${TAILSCALE_AUTH_KEY}" ]]; then
    info "Tailscale    : ${GREEN}enabled${TAILSCALE_TAGS:+ (tags=${TAILSCALE_TAGS})}${NC}"
else
    info "Tailscale    : ${GREEN}skipped (no auth key)${NC}"
fi

# =============================================================================
# TEMP bootstrap.env (uploaded alongside bootstrap.sh)
# =============================================================================
TMP_ENV="$(mktemp)"
trap 'rm -f "${TMP_ENV}"' EXIT
cat > "${TMP_ENV}" <<EOF
NEW_USER=${NEW_USER}
VPC_SUBNET=${VPC_SUBNET}
BASTION_CIDR=${BASTION_CIDR}
TIMEZONE=${TIMEZONE}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
TAILSCALE_TAGS=${TAILSCALE_TAGS}
SKIP_TAILSCALE=${SKIP_TAILSCALE}
EOF
chmod 600 "${TMP_ENV}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# =============================================================================
# BOOTSTRAP EACH HOST
# =============================================================================
TOTAL=$#; COUNT=0; FAILED=()

for HOST in "$@"; do
    COUNT=$((COUNT + 1))
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  [${COUNT}/${TOTAL}] Bootstrap ${HOST}${NC}"
    echo -e "${BLUE}============================================${NC}"

    info "Testing SSH to root@${HOST}..."
    if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@${HOST}" "echo OK" &>/dev/null; then
        warn "SSH failed — skipping ${HOST}"; FAILED+=("${HOST}"); continue
    fi
    log "SSH OK"

    info "Uploading bootstrap.sh + bootstrap.env..."
    scp "${SSH_OPTS[@]}" "${BOOTSTRAP_SCRIPT}" "root@${HOST}:/tmp/bootstrap.sh"
    scp "${SSH_OPTS[@]}" "${TMP_ENV}"          "root@${HOST}:/tmp/bootstrap.env"
    log "Upload done"

    info "Running bootstrap.sh on ${HOST}..."
    if ssh "${SSH_OPTS[@]}" "root@${HOST}" \
            "chmod +x /tmp/bootstrap.sh && /tmp/bootstrap.sh && rm -f /tmp/bootstrap.sh /tmp/bootstrap.env"; then
        log "Bootstrap ${HOST} SUCCESS"
    else
        warn "Bootstrap ${HOST} FAILED"; FAILED+=("${HOST}"); continue
    fi

    info "Testing SSH as ${NEW_USER}..."
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${NEW_USER}@${HOST}" "echo OK" &>/dev/null; then
        log "SSH ${NEW_USER}@${HOST} OK"
    else
        warn "SSH ${NEW_USER}@${HOST} failed — UFW may have blocked the source IP"
        warn "(not inside VPC_SUBNET / BASTION_CIDR). Check .env and re-run with -b."
        FAILED+=("${HOST}")
    fi
done

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Bootstrap Summary${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "User        : ${GREEN}${NEW_USER}${NC}"
echo -e "Total       : ${GREEN}${TOTAL}${NC}"
echo -e "Succeeded   : ${GREEN}$((TOTAL - ${#FAILED[@]}))${NC}"
echo -e "Failed      : ${RED}${#FAILED[@]}${NC}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""; warn "Failed hosts:"; for h in "${FAILED[@]}"; do echo "  - $h"; done; exit 1
fi

echo ""
log "All hosts bootstrapped."
echo ""
info "Next — deploy components as the non-root user:"
echo "  ./stream-auth/setup-stream-auth-remote.sh -u ${NEW_USER} <stream-auth-ip>"
echo "  ./haproxy/setup-haproxy-remote.sh         -u ${NEW_USER} <haproxy-ip>"
echo "  ./srs/setup-srs-remote.sh                 -u ${NEW_USER} <srs-ip>"
echo ""
