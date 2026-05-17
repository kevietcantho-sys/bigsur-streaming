# shellcheck shell=bash
# Common bash helpers. Source from every setup script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/../common/lib.sh"
#
# When uploaded by a remote wrapper, lib.sh lives next to the setup script:
#   . "${SCRIPT_DIR}/lib.sh"
#
# Each setup script handles both layouts itself (try local layout first, then
# colocated). Keep this file self-contained — no external deps.

set -euo pipefail

# --- logging ----------------------------------------------------------------
_log() {
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "$*" >&2
}
log()  { _log INFO  "$@"; }
ok()   { _log OK    "$@"; }
warn() { _log WARN  "$@"; }
die()  { _log ERROR "$@"; exit 1; }

# --- guards -----------------------------------------------------------------
require_root() {
  [[ ${EUID} -eq 0 ]] || die "must run as root (got UID ${EUID})"
}

require_ubuntu() {
  local id ver
  id=$(. /etc/os-release && echo "${ID:-}")
  ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
  [[ "${id}" == "ubuntu" ]] || die "this script supports Ubuntu only (found ${id} ${ver})"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Verify a VPC IP is bound on a local interface (catches mis-targeted runs).
# Matches the address list exactly — no substring/regex match, so 10.40.96.3
# does not falsely satisfy a box bound to 10.40.96.30.
require_local_ip() {
  local ip="$1"
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -qxF "${ip}" \
    || die "expected IP ${ip} not bound on any local interface"
}

# --- apt --------------------------------------------------------------------
APT_UPDATED=0
apt_update_once() {
  if [[ ${APT_UPDATED} -eq 0 ]]; then
    log "apt-get update"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  log "apt-get install: $*"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
}

# Force the next apt_install/apt_update_once to actually hit the index.
apt_invalidate_cache() {
  APT_UPDATED=0
}

# --- file editing -----------------------------------------------------------
# Append a line to a file only if it isn't already present.
idempotent_append() {
  local line="$1" file="$2"
  if [[ ! -f "${file}" ]] || ! grep -qxF "${line}" "${file}"; then
    printf '%s\n' "${line}" >> "${file}"
    log "appended to ${file}: ${line}"
  fi
}

# Read a value from a KEY=VALUE .env file without sourcing it (no shell exec).
# Usage: env_get /opt/streaming-auth/.env SIGN_API_TOKEN_DEFAULT
env_get() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || { echo ""; return 0; }
  grep -E "^${key}=" "${file}" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

# --- secret helpers ---------------------------------------------------------
# Generate a hex secret of given byte length (default 32 = 64 hex chars).
gen_hex() {
  local bytes="${1:-32}"
  require_cmd openssl
  openssl rand -hex "${bytes}"
}

# --- arg parsing ------------------------------------------------------------
# Usage: arg_required "$NAME" "$VALUE" "--flag"
arg_required() {
  local name="$1" value="${2:-}" flag="$3"
  [[ -n "${value}" ]] || die "${name} required (pass ${flag} or set in .env)"
}

# --- ufw --------------------------------------------------------------------
# Idempotent additive UFW: never resets existing rules; ensures defaults and
# enables the firewall. Pass rules via add_ufw_rule helper.
ensure_ufw_enabled() {
  require_cmd ufw
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  # Allow SSH BEFORE enabling so a fresh `--force enable` (default deny
  # incoming) can never strand the operator's session. Idempotent — callers
  # re-assert the same rule with the same comment.
  ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1 || true
  if ! ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw --force enable >/dev/null
  fi
}
