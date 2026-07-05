#!/usr/bin/env bash
# =============================================================================
# SRS origin — LL-HLS + HTTP-FLV, bound to VPC, hooked into stream-auth.
# Idempotent. Re-run safely.
# =============================================================================
#
# Required env vars:
#   SRS_VPC_IP            VPC IP on this box (must be locally bound)
#   HAPROXY_VPC_IP        HAProxy edge VPC IP (for UFW: HAProxy → SRS)
#   SRS_API_USER          SRS HTTP API basic-auth user
#   SRS_API_PASS          SRS HTTP API basic-auth password
#
# Optional:
#   STREAM_AUTH_VPC_IP    Where stream-auth runs (default: $HAPROXY_VPC_IP).
#                         Set this when stream-auth lives on its own VPS.
#                         SRS on_publish/on_unpublish hooks point here.
#   STREAM_AUTH_PORT      Default 3000
#   SRS_VERSION           SRS git tag (default v6.0-r0)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    . "${SCRIPT_DIR}/lib.sh"
elif [[ -f "${SCRIPT_DIR}/../common/lib.sh" ]]; then
    . "${SCRIPT_DIR}/../common/lib.sh"
else
    echo "lib.sh not found" >&2; exit 1
fi

require_root
require_ubuntu

SRS_VPC_IP="${SRS_VPC_IP:-}"
HAPROXY_VPC_IP="${HAPROXY_VPC_IP:-}"
STREAM_AUTH_VPC_IP="${STREAM_AUTH_VPC_IP:-${HAPROXY_VPC_IP}}"
SRS_API_USER="${SRS_API_USER:-}"
SRS_API_PASS="${SRS_API_PASS:-}"
STREAM_AUTH_PORT="${STREAM_AUTH_PORT:-3000}"
SRS_VERSION="${SRS_VERSION:-v6.0-r0}"

arg_required "SRS_VPC_IP"         "${SRS_VPC_IP}"         "SRS_VPC_IP=<ip>"
arg_required "HAPROXY_VPC_IP"     "${HAPROXY_VPC_IP}"     "HAPROXY_VPC_IP=<ip>"
arg_required "STREAM_AUTH_VPC_IP" "${STREAM_AUTH_VPC_IP}" "STREAM_AUTH_VPC_IP=<ip> (or HAPROXY_VPC_IP=<ip>)"
arg_required "SRS_API_USER"       "${SRS_API_USER}"       "SRS_API_USER=admin"
arg_required "SRS_API_PASS"       "${SRS_API_PASS}"       "SRS_API_PASS=<pass-from-STREAM_KEYS.txt>"
require_local_ip "${SRS_VPC_IP}"

# --- stop legacy services ---------------------------------------------------
for svc in nginx-rtmp nginx; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        warn "Stopping legacy ${svc}"
        systemctl stop "${svc}"
        systemctl disable "${svc}" 2>/dev/null || true
    fi
done
pkill -f 'objs/srs' 2>/dev/null || true
sleep 1

# --- packages ---------------------------------------------------------------
apt_install build-essential cmake automake autoconf libtool patch \
    libssl-dev pkg-config git wget curl unzip ufw python3

hostnamectl set-hostname srs-origin
idempotent_append "127.0.1.1 srs-origin" /etc/hosts

# --- user -------------------------------------------------------------------
if ! id srs >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin srs
    ok "Created system user: srs"
fi

# --- build SRS --------------------------------------------------------------
cd /opt
if [[ ! -d /opt/srs ]]; then
    log "Cloning SRS @ ${SRS_VERSION}..."
    git clone --depth 1 --branch "${SRS_VERSION}" https://github.com/ossrs/srs.git
else
    cd /opt/srs
    git fetch --tags --depth 1 origin "${SRS_VERSION}" || true
    git checkout "${SRS_VERSION}" || warn "Could not checkout ${SRS_VERSION}; using existing tree"
    cd /opt
fi

cd /opt/srs/trunk
BUILT_REV_FILE=objs/.srs-built-rev
CURRENT_REV="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
NEEDS_BUILD=0
if [[ ! -x objs/srs ]]; then
    NEEDS_BUILD=1
elif ldd objs/srs 2>/dev/null | grep -q libasan; then
    warn "Existing binary built with ASan; rebuilding without..."
    make clean >/dev/null 2>&1 || true
    NEEDS_BUILD=1
elif [[ "$(cat "${BUILT_REV_FILE}" 2>/dev/null || echo none)" != "${CURRENT_REV}" ]]; then
    # Source was checked out to a different revision (e.g. SRS_VERSION changed).
    warn "Existing binary built from a different revision; rebuilding for ${SRS_VERSION}..."
    make clean >/dev/null 2>&1 || true
    NEEDS_BUILD=1
fi

if [[ "${NEEDS_BUILD}" = "1" ]]; then
    log "Compiling SRS (5-10 min)..."
    ./configure --sanitizer=off
    make -j"$(nproc)"
    echo "${CURRENT_REV}" > "${BUILT_REV_FILE}"
    ok "SRS compiled (sanitizer=off)"
else
    ok "SRS binary present ($(./objs/srs -v 2>&1 | head -1))"
fi

# --- writable dirs ----------------------------------------------------------
mkdir -p /opt/srs/trunk/objs/nginx/html /var/log/srs /var/run/srs
chown -R srs:srs /opt/srs /var/log/srs /var/run/srs

# --- production config ------------------------------------------------------
log "Writing production config..."
cat > /opt/srs/trunk/conf/production.conf <<PRODCFG_EOF
# SRS Production Config — LL-HLS with auth, bound to VPC

listen              ${SRS_VPC_IP}:1935;
max_connections     1000;
daemon              off;
srs_log_tank        file;
srs_log_file        /var/log/srs/srs.log;
srs_log_level       trace;
pid                 /var/run/srs/srs.pid;

http_api {
    enabled         on;
    listen          ${SRS_VPC_IP}:1985;
    crossdomain     off;
    auth {
        enabled     on;
        username    ${SRS_API_USER};
        password    ${SRS_API_PASS};
    }
}

http_server {
    enabled         on;
    listen          ${SRS_VPC_IP}:8080;
    dir             ./objs/nginx/html;
    crossdomain     on;
}

stats { network 0; }

vhost __defaultVhost__ {
    tcp_nodelay         on;
    min_latency         on;

    play {
        gop_cache       off;
        queue_length    10;
        mw_latency      100;
    }

    publish {
        mr              off;
        # Close publish session if no media packet for 10s. Catches half-open
        # TCP (e.g. OBS killed) — without this, SRS waits on default OS
        # keepalive (hours) and on_unpublish never fires.
        normal_timeout      10000;
        firstpkt_timeout    20000;
    }

    http_hooks {
        enabled         on;
        on_publish      http://${STREAM_AUTH_VPC_IP}:${STREAM_AUTH_PORT}/srs/publish;
        on_unpublish    http://${STREAM_AUTH_VPC_IP}:${STREAM_AUTH_PORT}/srs/unpublish;
    }

    hls {
        enabled             on;
        hls_path            ./objs/nginx/html;
        hls_fragment        2;
        hls_window          20;
        hls_cleanup         on;
        # DISABLED (0): SRS 6.0.184 does not cancel the dispose timer armed by
        # an unpublish when the same stream name re-publishes within/after the
        # window — the timer later "gracefully disposes" the LIVE muxer, after
        # which the stream keeps ingesting but writes no HLS (playback 404s
        # until the next re-publish). Observed in prod 2026-07-05. Stale files
        # from ended streams are reaped by /etc/cron.d/srs-hls-cleanup instead.
        hls_dispose         0;
        hls_wait_keyframe   on;
        hls_ctx             off;
        hls_ts_ctx          off;
    }

    http_remux {
        enabled         on;
        fast_cache      30;
        mount           [vhost]/[app]/[stream].flv;
    }
}
PRODCFG_EOF
chown srs:srs /opt/srs/trunk/conf/production.conf
# 640 — file embeds SRS_API_PASS; keep it off world-readable.
chmod 640 /opt/srs/trunk/conf/production.conf
ok "Config written"

# --- TCP keepalive (kill half-open publishers fast) -------------------------
cat > /etc/sysctl.d/99-srs.conf <<'SYSCTL_EOF'
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
SYSCTL_EOF
sysctl -p /etc/sysctl.d/99-srs.conf >/dev/null
ok "TCP keepalive tuned"

# --- stale HLS cleanup (replaces hls_dispose, see hls config above) ----------
# Live playlists/segments are rewritten every ~2s, so anything untouched for
# 60 min belongs to an ended stream. Scoped to HLS file types only — SRS ships
# players/index.html in the same htdocs dir.
cat > /etc/cron.d/srs-hls-cleanup <<'CRON_EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/10 * * * *  srs  find /opt/srs/trunk/objs/nginx/html -type f \( -name '*.ts' -o -name '*.ts.tmp' -o -name '*.m3u8' \) -mmin +60 -delete
CRON_EOF
chmod 0644 /etc/cron.d/srs-hls-cleanup
ok "Stale-HLS cleanup cron installed (/etc/cron.d/srs-hls-cleanup)"

# tmpfiles for /var/run/srs
cat > /etc/tmpfiles.d/srs.conf <<'TMPF_EOF'
d /var/run/srs 0755 srs srs -
TMPF_EOF

# --- systemd unit -----------------------------------------------------------
cat > /etc/systemd/system/srs.service <<'SRSSVC_EOF'
[Unit]
Description=SRS Streaming Server
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=srs
Group=srs
WorkingDirectory=/opt/srs/trunk
LimitNOFILE=65535
ExecStart=/opt/srs/trunk/objs/srs -c conf/production.conf
ExecStop=/bin/kill -TERM $MAINPID
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
# AF_NETLINK required by getifaddrs() — SRS enumerates local interfaces
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
LockPersonality=yes
RestrictRealtime=yes
SystemCallArchitectures=native
ReadWritePaths=/opt/srs/trunk /var/log/srs /var/run/srs

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SRSSVC_EOF

cat > /etc/logrotate.d/srs <<'LROT_EOF'
/var/log/srs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su srs srs
}
LROT_EOF

systemctl daemon-reload
systemd-tmpfiles --create
systemctl enable srs >/dev/null
systemctl restart srs
sleep 3
systemctl is-active --quiet srs || die "SRS failed; journalctl -u srs"
ok "SRS running"

# --- firewall ---------------------------------------------------------------
log "Configuring firewall (additive)..."
ensure_ufw_enabled
ufw allow 22/tcp comment 'SSH' >/dev/null
ufw allow from "${HAPROXY_VPC_IP}" to any port 1935 proto tcp comment 'RTMP from HAProxy' >/dev/null
ufw allow from "${HAPROXY_VPC_IP}" to any port 8080 proto tcp comment 'HTTP from HAProxy' >/dev/null
ufw allow from "${HAPROXY_VPC_IP}" to any port 1985 proto tcp comment 'API from HAProxy' >/dev/null
ok "UFW rules applied"

# --- verify -----------------------------------------------------------------
log "Verifying..."
ss -tln | grep -q "${SRS_VPC_IP}:1935" && ok "RTMP listening" || warn "RTMP not listening"
ss -tln | grep -q "${SRS_VPC_IP}:8080" && ok "HTTP listening" || warn "HTTP not listening"
ss -tln | grep -q "${SRS_VPC_IP}:1985" && ok "API listening"  || warn "API not listening"

UNAUTH=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://${SRS_VPC_IP}:1985/api/v1/versions" || true)
[[ "${UNAUTH}" = "401" ]] && ok "API rejects anon (401)" || warn "API returned ${UNAUTH}, expected 401"

AUTH=$(curl -sf -m 3 -u "${SRS_API_USER}:${SRS_API_PASS}" "http://${SRS_VPC_IP}:1985/api/v1/versions" 2>/dev/null || true)
echo "${AUTH}" | grep -q '"version"' && ok "API authenticated OK" || warn "API auth failed"

# --- summary ----------------------------------------------------------------
cat <<EOF

═══════════════════════════════════════════════════════════════
  SRS ORIGIN SETUP COMPLETE
═══════════════════════════════════════════════════════════════
  VPC IP:         ${SRS_VPC_IP}
  HAProxy:        ${HAPROXY_VPC_IP}
  Stream-auth:    ${STREAM_AUTH_VPC_IP}:${STREAM_AUTH_PORT}
  SRS version:    ${SRS_VERSION}
  Running as:     srs (non-root)

  Endpoints (VPC only):
    RTMP:           ${SRS_VPC_IP}:1935
    HTTP/HLS:       ${SRS_VPC_IP}:8080
    API (authed):   ${SRS_VPC_IP}:1985

  Service:        $(systemctl is-active srs)
  Logs:           journalctl -u srs -f
                  tail -f /var/log/srs/srs.log
═══════════════════════════════════════════════════════════════
EOF
