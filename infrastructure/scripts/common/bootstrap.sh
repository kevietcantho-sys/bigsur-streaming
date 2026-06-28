#!/usr/bin/env bash
# =============================================================================
# Bootstrap — run as ROOT once on a fresh box BEFORE any setup-*.sh script.
# Applies to every bigsur-streaming box: stream-auth, haproxy, srs.
# Creates a non-root sudo user, copies SSH keys, basic hardening, UFW.
# =============================================================================
#
# After this runs you can deploy components as the non-root user, e.g.:
#   ./haproxy/setup-haproxy-remote.sh -u <NEW_USER> <host>
# The wrappers detect a non-root SSH_USER and prefix `sudo -E` automatically.
#
# Config resolved by precedence (high -> low):
#   1. Env vars passed to the script (NEW_USER, VPC_SUBNET, BASTION_CIDR,
#      TIMEZONE, TAILSCALE_AUTH_KEY, TAILSCALE_HOSTNAME, TAILSCALE_TAGS)
#   2. /tmp/bootstrap.env (uploaded alongside by bootstrap-remote.sh)
#   3. Defaults in this script
#
# UFW:
#   - default deny incoming, allow outgoing
#   - allow SSH (22/tcp) only from VPC_SUBNET (+ BASTION_CIDR if set)
#   - allow in on tailscale0 if Tailscale installed
#   - enable UFW (pre-flight check avoids locking out the current SSH session)
# Service-specific ports (HAProxy 80/443/1935/1936, stream-auth :3000, SRS
# :8080, ...) are opened later by each setup-*.sh script.
#
# Tailscale (optional):
#   - Skipped if TAILSCALE_AUTH_KEY is empty OR SKIP_TAILSCALE=1.
#   - Installed via the official install.sh; joins the tailnet with --ssh.
#   - Does NOT advertise routes (that is the subnet-router's job).
# =============================================================================

set -euo pipefail

# =============================================================================
# LOAD .env (if bootstrap-remote.sh uploaded one)
# =============================================================================
if [[ -f /tmp/bootstrap.env ]]; then
    # shellcheck disable=SC1091
    set -a; . /tmp/bootstrap.env; set +a
fi

# =============================================================================
# CONFIG (env-var overridable)
# =============================================================================
NEW_USER="${NEW_USER:-ubuntu}"
VPC_SUBNET="${VPC_SUBNET:-10.40.96.0/20}"
BASTION_CIDR="${BASTION_CIDR:-}"
TIMEZONE="${TIMEZONE:-Asia/Ho_Chi_Minh}"

# --- Tailscale (optional) ---
# Skip the Tailscale step when:
#   - TAILSCALE_AUTH_KEY is empty, OR
#   - SKIP_TAILSCALE=1 (per-node opt-out, keeps the shared auth key in .env).
SKIP_TAILSCALE="${SKIP_TAILSCALE:-0}"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-$(hostname)}"
TAILSCALE_TAGS="${TAILSCALE_TAGS:-}"        # "tag:service,tag:production"

# Normalize SKIP_TAILSCALE: accept 1/true/yes (case-insensitive) -> 1, else 0.
case "${SKIP_TAILSCALE,,}" in
    1|true|yes|y) SKIP_TAILSCALE=1 ;;
    *)            SKIP_TAILSCALE=0 ;;
esac

# Effective flag: Tailscale "enabled" when an auth key is present AND not skipped.
TAILSCALE_ENABLED=0
if [[ -n "$TAILSCALE_AUTH_KEY" && "$SKIP_TAILSCALE" -eq 0 ]]; then
    TAILSCALE_ENABLED=1
fi

# =============================================================================
# COLORS / LOGGING
# =============================================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# =============================================================================
# GUARDS
# =============================================================================
[[ $EUID -ne 0 ]] && fail "This script must run as root."
[[ -z "$NEW_USER"   ]] && fail "NEW_USER is empty."
[[ -z "$VPC_SUBNET" ]] && fail "VPC_SUBNET is empty."

log "Bootstrap box"
log "  NEW_USER     : $NEW_USER"
log "  VPC_SUBNET   : $VPC_SUBNET"
log "  BASTION_CIDR : ${BASTION_CIDR:-<empty>}"
log "  TIMEZONE     : $TIMEZONE"
if [[ "$TAILSCALE_ENABLED" -eq 1 ]]; then
    log "  TAILSCALE    : enabled (host=$TAILSCALE_HOSTNAME${TAILSCALE_TAGS:+, tags=$TAILSCALE_TAGS})"
elif [[ "$SKIP_TAILSCALE" -eq 1 ]]; then
    log "  TAILSCALE    : skipped (SKIP_TAILSCALE=1)"
else
    log "  TAILSCALE    : skipped (TAILSCALE_AUTH_KEY empty)"
fi

# =============================================================================
# 1. APT MIRROR PRE-FLIGHT — regional cloud mirrors are sometimes flaky. Probe
# BEFORE the cloud-init wait, because cloud-init's package_update uses the same
# mirror — if it stalls, the wait step below deadlocks.
# =============================================================================
log "Checking apt mirror..."
# Codename of the running release (jammy / noble / ...). Used to probe the
# mirror's InRelease so this works on both Ubuntu 22.04 and 24.04.
RELEASE_CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
APT_MIRROR_HOST="$(
    grep -hoE '[a-z0-9]+\.clouds\.archive\.ubuntu\.com' \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d/*.sources \
        /etc/apt/sources.list.d/*.list 2>/dev/null \
    | head -1 || true
)"
if [[ -n "$APT_MIRROR_HOST" && -n "$RELEASE_CODENAME" ]]; then
    # HTTP probe (not just TCP): a stalled mirror commonly completes the TCP
    # handshake but never returns a body.
    if curl --max-time 10 --connect-timeout 5 -sfI \
            "http://$APT_MIRROR_HOST/ubuntu/dists/$RELEASE_CODENAME/InRelease" \
            >/dev/null 2>&1; then
        log "  → $APT_MIRROR_HOST OK"
    else
        warn "  → $APT_MIRROR_HOST unreachable/stalled, falling back to archive.ubuntu.com"
        for f in /etc/apt/sources.list \
                 /etc/apt/sources.list.d/*.sources \
                 /etc/apt/sources.list.d/*.list; do
            [[ -f "$f" ]] && sed -i "s|$APT_MIRROR_HOST|archive.ubuntu.com|g" "$f"
        done
        # Cloud-init may be hung on the dead mirror — kill stuck apt processes
        # so cloud-init unblocks and picks up the new sources.
        warn "  → killing apt processes stuck on the old mirror..."
        pkill -9 -f "apt-get" 2>/dev/null || true
        pkill -9 -f "/usr/lib/apt/methods/http" 2>/dev/null || true
    fi
fi

# =============================================================================
# 2. WAIT FOR CLOUD-INIT / APT LOCKS — fresh boxes run unattended-upgrades on
# first boot and hold /var/lib/dpkg/lock-frontend for the first few minutes.
# =============================================================================
log "Waiting for cloud-init + apt locks (first boot)..."
if command -v cloud-init >/dev/null 2>&1; then
    # --wait can block forever if cloud-init died half-way. Bound it to 5 min;
    # the apt_busy loop below keeps polling the lock afterwards.
    timeout 300 cloud-init status --wait >/dev/null 2>&1 || true
fi
# fuser comes from psmisc — absent on some minimal images, fall back to pgrep.
apt_busy() {
    if command -v fuser >/dev/null 2>&1; then
        fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock \
            >/dev/null 2>&1
    else
        pgrep -x apt -x apt-get -x dpkg >/dev/null 2>&1 || \
            pgrep -f unattended-upgrade >/dev/null 2>&1
    fi
}
WAITED=0
while apt_busy; do
    if (( WAITED >= 600 )); then
        fail "apt locks still busy after 10 min. Check: ps -ef | grep apt"
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    # Print progress every 30s so it's clear the script is alive.
    (( WAITED % 30 == 0 )) && log "  ... waited ${WAITED}s"
done
[[ $WAITED -gt 0 ]] && log "  → waited ${WAITED}s for the lock"

# =============================================================================
# 3. UPDATE SYSTEM + BASE PACKAGES
# =============================================================================
log "Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl wget git unzip jq ufw fail2ban ca-certificates iproute2 psmisc python3

# =============================================================================
# 4. CREATE NON-ROOT USER
# =============================================================================
if id "$NEW_USER" &>/dev/null; then
    warn "User '$NEW_USER' already exists — skipping creation"
else
    log "Creating user '$NEW_USER'..."
    adduser --disabled-password --gecos "" "$NEW_USER"
fi

# =============================================================================
# 5. PASSWORDLESS SUDO
# =============================================================================
log "Configuring sudo..."
usermod -aG sudo "$NEW_USER"
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
chmod 0440 "/etc/sudoers.d/$NEW_USER"

# =============================================================================
# 6. COPY SSH KEY FROM ROOT
# =============================================================================
log "Copying SSH authorized_keys from root to '$NEW_USER'..."
if [[ ! -f /root/.ssh/authorized_keys ]]; then
    fail "/root/.ssh/authorized_keys not found"
fi
USER_HOME="/home/$NEW_USER"
mkdir -p "$USER_HOME/.ssh"
cp /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"

# =============================================================================
# 7. PERSIST CONFIG FOR LATER SCRIPTS
# =============================================================================
# Setup scripts can source this to learn NEW_USER, VPC_SUBNET, BASTION_CIDR,
# TIMEZONE: . /etc/bigsur/bootstrap.env
log "Writing /etc/bigsur/bootstrap.env..."
mkdir -p /etc/bigsur
cat > /etc/bigsur/bootstrap.env <<EOF
# Generated by infrastructure/scripts/common/bootstrap.sh
# Source this in setup scripts: . /etc/bigsur/bootstrap.env
NEW_USER=$NEW_USER
VPC_SUBNET=$VPC_SUBNET
BASTION_CIDR=$BASTION_CIDR
TIMEZONE=$TIMEZONE
EOF
chmod 0644 /etc/bigsur/bootstrap.env

# Also export into every new shell (login + non-login) for convenience.
cat > /etc/profile.d/bigsur-env.sh <<'EOF'
# Generated by infrastructure/scripts/common/bootstrap.sh
if [ -r /etc/bigsur/bootstrap.env ]; then
    set -a
    . /etc/bigsur/bootstrap.env
    set +a
fi
EOF
chmod 0644 /etc/profile.d/bigsur-env.sh

# =============================================================================
# 8. FAIL2BAN
# =============================================================================
log "Configuring fail2ban..."
tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# =============================================================================
# 9. INSTALL TAILSCALE (optional — skip when TAILSCALE_AUTH_KEY empty)
# =============================================================================
TAILSCALE_IP=""
if [[ "$TAILSCALE_ENABLED" -ne 1 ]]; then
    if [[ "$SKIP_TAILSCALE" -eq 1 ]]; then
        log "Skipping Tailscale (SKIP_TAILSCALE=1)"
    else
        log "Skipping Tailscale (TAILSCALE_AUTH_KEY empty)"
    fi
else
    if command -v tailscale >/dev/null 2>&1; then
        warn "tailscale already installed — skipping install"
    else
        log "Installing Tailscale (official install.sh)..."
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # Build args for `tailscale up` — do NOT advertise routes here
    # (subnet routing is the bastion's job).
    TAILSCALE_UP_ARGS=(
        --authkey="$TAILSCALE_AUTH_KEY"
        --ssh
        --hostname="$TAILSCALE_HOSTNAME"
    )
    if [[ -n "$TAILSCALE_TAGS" ]]; then
        TAILSCALE_UP_ARGS+=(--advertise-tags="$TAILSCALE_TAGS")
    fi

    log "tailscale up (host=$TAILSCALE_HOSTNAME${TAILSCALE_TAGS:+, tags=$TAILSCALE_TAGS})..."
    tailscale up "${TAILSCALE_UP_ARGS[@]}"

    TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    log "Tailscale IP: ${TAILSCALE_IP:-<not ready — check: tailscale status>}"
fi

# =============================================================================
# 10. SSH HARDENING
# =============================================================================
log "Hardening SSH..."
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh 2>/dev/null || systemctl restart sshd

# =============================================================================
# 11. UFW — SSH ONLY FROM VPC (+ BASTION_CIDR if set), ENABLE NOW
# =============================================================================
log "Configuring UFW (allow SSH from VPC$([[ -n "$BASTION_CIDR" ]] && echo " + $BASTION_CIDR")$([[ "$TAILSCALE_ENABLED" -eq 1 ]] && echo " + tailscale0"))..."

# Pre-flight: make sure the current SSH session's source IP is inside an
# allowed CIDR, otherwise enabling UFW would drop this session immediately.
# If Tailscale is enabled, also accept the CGNAT range (100.64.0.0/10) since
# allow-on-tailscale0 covers it after enable.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    SSH_CLIENT_IP="$(awk '{print $1}' <<<"$SSH_CONNECTION")"
    covered=0
    PREFLIGHT_CIDRS=("$VPC_SUBNET")
    [[ -n "$BASTION_CIDR"            ]] && PREFLIGHT_CIDRS+=("$BASTION_CIDR")
    [[ "$TAILSCALE_ENABLED" -eq 1    ]] && PREFLIGHT_CIDRS+=("100.64.0.0/10")
    for cidr in "${PREFLIGHT_CIDRS[@]}"; do
        # python3 (installed above) checks ip-in-cidr.
        if python3 - "$SSH_CLIENT_IP" "$cidr" <<'PY' 2>/dev/null
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
net = ipaddress.ip_network(sys.argv[2], strict=False)
sys.exit(0 if ip in net else 1)
PY
        then
            covered=1
            break
        fi
    done
    if [[ $covered -eq 0 ]]; then
        warn "SSH client $SSH_CLIENT_IP is NOT inside VPC_SUBNET or BASTION_CIDR."
        warn "Enabling UFW now would drop this session and lock you out."
        warn "How to fix:"
        warn "  - Set BASTION_CIDR=$SSH_CLIENT_IP/32 (or 0.0.0.0/0 for the first run)"
        warn "    then re-run bootstrap.sh."
        warn "  - OR run directly from the provider console."
        fail "Aborted: SSH source is not allowed."
    fi
fi

# Reset existing rules so this runs idempotently.
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

# SSH from VPC
ufw allow from "$VPC_SUBNET" to any port 22 proto tcp \
    comment 'SSH from VPC'

# SSH from BASTION_CIDR (if set)
if [[ -n "$BASTION_CIDR" ]]; then
    ufw allow from "$BASTION_CIDR" to any port 22 proto tcp \
        comment 'SSH from bastion/operator'
fi

# Tailscale: allow all inbound on tailscale0 (keep port 22 from VPC above as a
# fallback if the tailnet is down).
if [[ "$TAILSCALE_ENABLED" -eq 1 ]]; then
    ufw allow in on tailscale0 comment 'Tailscale tailnet'
    ufw allow 41641/udp        comment 'Tailscale UDP'
fi

ufw --force enable
log "UFW enabled — SSH only from VPC$([[ -n "$BASTION_CIDR" ]] && echo " + $BASTION_CIDR")$([[ "$TAILSCALE_ENABLED" -eq 1 ]] && echo " + tailscale0")"

# =============================================================================
# 12. TIMEZONE
# =============================================================================
log "Setting timezone $TIMEZONE..."
timedatectl set-timezone "$TIMEZONE"

# =============================================================================
# 13. TEST SUDO
# =============================================================================
log "Testing sudo for user '$NEW_USER'..."
sudo -u "$NEW_USER" sudo -n true 2>/dev/null || fail "Sudo is not working"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Bootstrap complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "New user     : ${GREEN}$NEW_USER${NC}"
echo -e "Hostname     : ${GREEN}$(hostname)${NC}"
echo -e "VPC subnet   : ${GREEN}$VPC_SUBNET${NC}"
echo -e "Bastion CIDR : ${GREEN}${BASTION_CIDR:-<empty>}${NC}"
echo -e "Config file  : ${GREEN}/etc/bigsur/bootstrap.env${NC}"
if [[ "$TAILSCALE_ENABLED" -eq 1 ]]; then
    echo -e "Tailscale    : ${GREEN}${TAILSCALE_HOSTNAME}${NC} (${TAILSCALE_IP:-<n/a>})${TAILSCALE_TAGS:+ tags=${TAILSCALE_TAGS}}"
elif [[ "$SKIP_TAILSCALE" -eq 1 ]]; then
    echo -e "Tailscale    : ${YELLOW}skipped (SKIP_TAILSCALE=1)${NC}"
fi
echo ""
warn "Next steps:"
echo "  1. Test SSH with the new user (in a SEPARATE terminal, do NOT close root):"
echo "     ssh $NEW_USER@<box-ip>"
echo ""
echo "  2. Deploy components as the non-root user (wrappers add 'sudo -E'):"
echo "     ./stream-auth/setup-stream-auth-remote.sh -u $NEW_USER <host>"
echo "     ./haproxy/setup-haproxy-remote.sh         -u $NEW_USER <host>"
echo "     ./srs/setup-srs-remote.sh                 -u $NEW_USER <host>"
echo ""
