#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
# Streaming Infrastructure Setup - HAProxy Edge + SRS Origin (PRODUCTION)
#═══════════════════════════════════════════════════════════════════════════════
# Usage:
#   bash setup-streaming-infra.sh haproxy   # Run on haproxy-edge server
#   bash setup-streaming-infra.sh srs       # Run on srs-origin server
#
# Architecture (production):
#   OBS ── RTMPS:1936 ──► HAProxy (TLS term) ── RTMP ──► SRS:1935 (VPC)
#                                                          │ Generate LL-HLS
#   Viewer ── HTTPS:443 ── BunnyCDN ── HTTPS:443 ── HAProxy ── HTTP ── SRS:8080 (VPC)
#
# Hardening applied vs previous version:
#   [S1]  TLS on 443 via CF Origin Cert; 1936 (RTMPS) via Let's Encrypt
#   [S2]  HTTP/80 and RTMP/1935 only redirect or disabled on public iface
#   [S3]  Services run as non-root dedicated users (streaming-auth, srs)
#   [S4]  Systemd hardening (NoNewPrivileges, ProtectSystem, etc.)
#   [S5]  Firewall: additive ufw rules (no --force reset)
#   [S6]  SRS pinned to stable tag v6.0-r0 (not develop branch)
#   [S7]  Dead HMAC secrets removed; added SIGN_API_TOKEN bearer auth on /sign
#   [S8]  /sign fails closed when BunnyCDN not configured (returns 503)
#   [S9]  Rate limiting + input validation on /sign
#   [S10] SRS http_api protected by basic auth
#   [S11] set -euo pipefail; errors no longer silenced
#   [S12] Systemd restart loops bounded (StartLimitBurst)
#   [S13] Log rotation via journald (no unbounded /var/log files)
#═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

#───────────────────────────────────────────────────────────────────────────────
# Configuration - UPDATE THESE FOR YOUR ENVIRONMENT
#───────────────────────────────────────────────────────────────────────────────
HAPROXY_VPC_IP="${HAPROXY_VPC_IP:-10.40.96.3}"
SRS_VPC_IP="${SRS_VPC_IP:-10.40.96.4}"
HAPROXY_PUBLIC_IP="${HAPROXY_PUBLIC_IP:-45.76.145.205}"

# TLS config — REQUIRED for production
# Set ALLOW_NO_TLS=1 to skip (dev/testing only, NOT recommended)
#
# Two public hostnames are required (both resolve to HAPROXY_PUBLIC_IP):
#
#   PUBLISH_HOST          — OBS push endpoint (RTMPS/RTMP). MUST be grey-cloud
#                           (DNS only) in Cloudflare since CF does not proxy
#                           ports 1935/1936.
#   PLAYBACK_ORIGIN_HOST  — HLS origin that BunnyCDN pulls from. Recommend
#                           grey-cloud to avoid stacking two CDNs.
#
# TLS certificate (Cloudflare Origin Certificate) must be valid for BOTH
# hostnames. Easiest: issue a wildcard for *.yourdomain.com in Cloudflare
# dashboard (SSL/TLS → Origin Server → Create Certificate), then upload to
# $SSL_CERT_PATH + $SSL_KEY_PATH. Cloudflare SSL/TLS mode: "Full (strict)".
PUBLISH_HOST="${PUBLISH_HOST:-}"                  # e.g. bspush.example.com
PLAYBACK_ORIGIN_HOST="${PLAYBACK_ORIGIN_HOST:-}"  # e.g. origin.example.com
SSL_CERT_PATH="${SSL_CERT_PATH:-/etc/ssl/cloudflare/origin.pem}"
SSL_KEY_PATH="${SSL_KEY_PATH:-/etc/ssl/cloudflare/origin.key}"
ALLOW_NO_TLS="${ALLOW_NO_TLS:-0}"

# Let's Encrypt for RTMPS on :1936 (publicly-trusted cert for OBS).
# Requires port 80 reachable from the internet (HTTP-01 challenge).
# If empty, :1936 falls back to the CF Origin Cert (OBS will reject it).
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

# Pin SRS version (do NOT use develop in production)
SRS_VERSION="v6.0-r0"

#───────────────────────────────────────────────────────────────────────────────
# Colors / logging
#───────────────────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()  { echo "${BLUE}[INFO]${NC} $1"; }
ok()   { echo "${GREEN}[ OK ]${NC} $1"; }
warn() { echo "${YELLOW}[WARN]${NC} $1"; }
err()  { echo "${RED}[FAIL]${NC} $1" >&2; exit 1; }

#───────────────────────────────────────────────────────────────────────────────
# Role selection + preflight
#───────────────────────────────────────────────────────────────────────────────
ROLE="${1:-}"
if [ -z "$ROLE" ]; then
    cat >&2 <<USAGE
Usage: bash $0 <haproxy|srs>

  haproxy  = Setup HAProxy edge + TLS + auth service + BunnyCDN integration
  srs      = Setup SRS streaming server (LL-HLS + HTTP-FLV)

Required environment variables for HAProxy role:
  PUBLISH_HOST          OBS ingest hostname (grey-cloud DNS → HAPROXY_PUBLIC_IP)
  PLAYBACK_ORIGIN_HOST  HLS origin pulled by BunnyCDN (grey-cloud → HAPROXY_PUBLIC_IP)
  SSL_CERT_PATH         Cloudflare Origin Cert (default: /etc/ssl/cloudflare/origin.pem)
  SSL_KEY_PATH          Cloudflare Origin Cert key (default: /etc/ssl/cloudflare/origin.key)

Optional overrides:
  HAPROXY_VPC_IP, SRS_VPC_IP, HAPROXY_PUBLIC_IP
  LETSENCRYPT_EMAIL     Enable Let's Encrypt for RTMPS on :1936 (OBS needs a
                        publicly-trusted cert; CF Origin Cert is rejected).
                        Requires public port 80 for HTTP-01 challenge.
  ALLOW_NO_TLS=1        Skip TLS (dev only; DO NOT use in production)

Example:
  PUBLISH_HOST=bspush.example.com PLAYBACK_ORIGIN_HOST=origin.example.com \\
      LETSENCRYPT_EMAIL=ops@example.com bash $0 haproxy
USAGE
    exit 1
fi

[ "$(id -u)" -eq 0 ] || err "Must run as root"

# Validate TLS config for haproxy role
if [ "$ROLE" = "haproxy" ]; then
    if [ "$ALLOW_NO_TLS" != "1" ]; then
        [ -z "$PUBLISH_HOST" ]         && err "PUBLISH_HOST not set (e.g. bspush.example.com)."
        [ -z "$PLAYBACK_ORIGIN_HOST" ] && err "PLAYBACK_ORIGIN_HOST not set (e.g. origin.example.com)."
        [ -f "$SSL_CERT_PATH" ] || err "SSL_CERT_PATH not found: $SSL_CERT_PATH. Upload Cloudflare Origin Certificate first."
        [ -f "$SSL_KEY_PATH" ]  || err "SSL_KEY_PATH not found: $SSL_KEY_PATH. Upload Cloudflare Origin private key first."
    else
        warn "ALLOW_NO_TLS=1 — TLS disabled. DO NOT use this in production."
    fi
fi

#═══════════════════════════════════════════════════════════════════════════════
# HAPROXY EDGE SETUP
#═══════════════════════════════════════════════════════════════════════════════
setup_haproxy() {
    log "Setting up HAProxy edge (production hardened)..."

    #─── Pre-flight ────────────────────────────────────────────────────────────
    ip -4 addr show | grep -q "$HAPROXY_VPC_IP" || err "VPC IP $HAPROXY_VPC_IP not found on any interface"
    ok "VPC IP confirmed: $HAPROXY_VPC_IP"

    #─── Packages ──────────────────────────────────────────────────────────────
    log "Installing packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    if ! command -v node >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi
    apt-get install -y haproxy certbot ufw vnstat htop curl wget git jq python3
    ok "Packages installed (node $(node -v), haproxy $(haproxy -v 2>&1 | head -1 | awk '{print $3}'))"

    #─── Hostname ──────────────────────────────────────────────────────────────
    hostnamectl set-hostname haproxy-edge
    grep -q "haproxy-edge" /etc/hosts || echo "127.0.1.1 haproxy-edge" >> /etc/hosts

    #─── Dedicated user for auth service ───────────────────────────────────────
    if ! id streaming-auth >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin streaming-auth
        ok "Created system user: streaming-auth"
    fi

    #─── TLS certificates ──────────────────────────────────────────────────────
    # Two certs by role:
    #   /etc/haproxy/certs/origin.pem   — Cloudflare Origin Certificate, used on
    #                                     :443 (HTTPS). BunnyCDN pulls this; the
    #                                     pull zone must have "Verify origin SSL"
    #                                     off (CF Origin CA is not publicly
    #                                     trusted).
    #   /etc/haproxy/certs/publish.pem  — Let's Encrypt cert for $PUBLISH_HOST,
    #                                     used on :1936 (RTMPS). OBS validates
    #                                     against public roots, so we need LE.
    #                                     Falls back to origin.pem if
    #                                     $LETSENCRYPT_EMAIL is unset (OBS will
    #                                     reject — use plain RTMP :1935 then).
    RTMPS_CERT_PATH=/etc/haproxy/certs/origin.pem
    if [ "$ALLOW_NO_TLS" != "1" ]; then
        mkdir -p /etc/haproxy/certs
        chmod 750 /etc/haproxy/certs
        chown root:haproxy /etc/haproxy/certs

        log "Building combined PEM from $SSL_CERT_PATH + $SSL_KEY_PATH..."
        cat "$SSL_CERT_PATH" "$SSL_KEY_PATH" > /etc/haproxy/certs/origin.pem
        chmod 640 /etc/haproxy/certs/origin.pem
        chown root:haproxy /etc/haproxy/certs/origin.pem
        ok "HTTPS cert ready at /etc/haproxy/certs/origin.pem (Cloudflare Origin)"

        if [ -n "$LETSENCRYPT_EMAIL" ]; then
            local LE_LIVE="/etc/letsencrypt/live/${PUBLISH_HOST}"
            if [ ! -f "$LE_LIVE/fullchain.pem" ]; then
                log "Obtaining Let's Encrypt cert for $PUBLISH_HOST (HTTP-01 on :80)..."
                # Stop HAProxy if running so certbot --standalone can bind :80.
                # First-run: haproxy not yet started. Re-run: ~5s downtime.
                systemctl stop haproxy 2>/dev/null || true
                certbot certonly --standalone --non-interactive --agree-tos \
                    -m "$LETSENCRYPT_EMAIL" -d "$PUBLISH_HOST" \
                    --preferred-challenges http
                ok "Let's Encrypt cert issued for $PUBLISH_HOST"
            else
                ok "Let's Encrypt cert already present for $PUBLISH_HOST"
            fi

            # Combined PEM for HAProxy :1936
            cat "$LE_LIVE/fullchain.pem" "$LE_LIVE/privkey.pem" \
                > /etc/haproxy/certs/publish.pem
            chmod 640 /etc/haproxy/certs/publish.pem
            chown root:haproxy /etc/haproxy/certs/publish.pem
            RTMPS_CERT_PATH=/etc/haproxy/certs/publish.pem

            # Renewal hooks:
            #   pre   — stop haproxy so certbot can bind :80
            #   post  — start haproxy back up
            #   deploy— rebuild combined PEM (runs only on successful renewal)
            mkdir -p /etc/letsencrypt/renewal-hooks/pre \
                     /etc/letsencrypt/renewal-hooks/post \
                     /etc/letsencrypt/renewal-hooks/deploy

            cat > /etc/letsencrypt/renewal-hooks/pre/haproxy-stop.sh <<'PRE_EOF'
#!/bin/bash
systemctl stop haproxy
PRE_EOF
            cat > /etc/letsencrypt/renewal-hooks/post/haproxy-start.sh <<'POST_EOF'
#!/bin/bash
systemctl start haproxy
POST_EOF
            cat > /etc/letsencrypt/renewal-hooks/deploy/haproxy-publish.sh <<HOOK_EOF
#!/bin/bash
set -e
cat /etc/letsencrypt/live/${PUBLISH_HOST}/fullchain.pem \\
    /etc/letsencrypt/live/${PUBLISH_HOST}/privkey.pem \\
    > /etc/haproxy/certs/publish.pem
chmod 640 /etc/haproxy/certs/publish.pem
chown root:haproxy /etc/haproxy/certs/publish.pem
HOOK_EOF
            chmod +x /etc/letsencrypt/renewal-hooks/pre/haproxy-stop.sh \
                     /etc/letsencrypt/renewal-hooks/post/haproxy-start.sh \
                     /etc/letsencrypt/renewal-hooks/deploy/haproxy-publish.sh
            ok "RTMPS cert: /etc/haproxy/certs/publish.pem (Let's Encrypt, auto-renew)"
        else
            warn "LETSENCRYPT_EMAIL unset — :1936 will serve the CF Origin Cert (OBS will reject). Use plain RTMP on :1935."
        fi
    fi

    #─── Auth service (NestJS, build on server) ───────────────────────────────
    # Source must be colocated with this script (streaming-auth/ next to setup-streaming-infra.sh)
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local SRC_DIR="$SCRIPT_DIR/streaming-auth"
    local APP_DIR="/opt/streaming-auth"

    [ -d "$SRC_DIR" ] || err "streaming-auth source not found at $SRC_DIR. Upload the whole repo to this box."
    [ -f "$SRC_DIR/package.json" ] || err "$SRC_DIR/package.json missing — source tree looks incomplete."

    log "Deploying NestJS auth service from $SRC_DIR to $APP_DIR..."
    apt-get install -y rsync >/dev/null

    mkdir -p "$APP_DIR"
    # Sync source; exclude build artifacts, deps, and local env. .env in APP_DIR is preserved.
    rsync -a --delete \
        --exclude 'node_modules/' \
        --exclude 'dist/' \
        --exclude 'coverage/' \
        --exclude '.env' \
        --exclude '.env.*' \
        --exclude '*.log' \
        "$SRC_DIR/" "$APP_DIR/"

    # Build artifacts live under $APP_DIR. Node 20 already installed above.
    log "Installing npm deps (incl. devDeps for build)..."
    ( cd "$APP_DIR" && npm ci --no-audit --no-fund )

    log "Compiling TypeScript (nest build)..."
    ( cd "$APP_DIR" && npm run build )

    log "Pruning dev dependencies..."
    ( cd "$APP_DIR" && npm prune --omit=dev --no-audit --no-fund )

    # Generate keys if .env doesn't exist
    if [ ! -f "$APP_DIR/.env" ]; then
        SIGN_API_TOKEN=$(openssl rand -hex 32)
        SRS_API_PASS=$(openssl rand -hex 16)
        STUDIO1_KEY=$(openssl rand -hex 12)
        STUDIO2_KEY=$(openssl rand -hex 12)

        cat > "$APP_DIR/.env" <<EOF
# ═══════════════════════════════════════════════════════════════
# streaming-auth (NestJS) — secrets and env overrides
# Base defaults live in config/default.yaml. Env vars win over YAML.
# ═══════════════════════════════════════════════════════════════

# Bearer token required to call POST /sign (backend only)
SIGN_API_TOKEN=$SIGN_API_TOKEN

# Per-stream publish keys (OBS stream key: <stream>?key=<secret>)
STREAM_KEYS=studio1:$STUDIO1_KEY,studio2:$STUDIO2_KEY

# BunnyCDN — REQUIRED. /sign fails closed (503) until both are set.
BUNNY_TOKEN_KEY=
BUNNY_CDN_URL=

# SRS API basic auth (used by monitoring only; set on SRS box too)
SRS_API_USER=admin
SRS_API_PASS=$SRS_API_PASS

# Auth service bind (overrides YAML)
PORT=3000
BIND_IP=$HAPROXY_VPC_IP

# Upstream SRS (informational)
ORIGIN_HOST=$SRS_VPC_IP
ORIGIN_PORT=8080

# Logging (journald captures stdout; keep JSON for structured logs)
LOG_LEVEL=info
LOG_FORMAT=json

NODE_ENV=production
EOF
        chmod 640 "$APP_DIR/.env"

        # Save credentials for operator
        cat > /root/STREAM_KEYS.txt <<EOF
═══════════════════════════════════════════════════════════════
  STREAM INFRASTRUCTURE CREDENTIALS — Generated $(date)
  Server: haproxy-edge ($HAPROXY_PUBLIC_IP)
  KEEP THIS FILE PRIVATE. chmod 600.

  === OBS PUBLISHER ===
  Server (RTMPS):  rtmps://${PUBLISH_HOST:-$HAPROXY_PUBLIC_IP}:1936/live
  Server (RTMP):   rtmp://${PUBLISH_HOST:-$HAPROXY_PUBLIC_IP}/live   # fallback only
  Stream keys:
    studio1?key=$STUDIO1_KEY
    studio2?key=$STUDIO2_KEY

  === BACKEND → AUTH API ===
  Sign endpoint:   https://${PLAYBACK_ORIGIN_HOST:-$HAPROXY_PUBLIC_IP}/sign
  Authorization header: Bearer $SIGN_API_TOKEN

  === SRS HTTP API (internal monitoring) ===
  User: admin
  Pass: $SRS_API_PASS
  (Set the same values on the SRS box; used by on the srs role below.)

  === NEXT STEPS ===
  1) Create BunnyCDN pull zone. Origin URL:
       https://${PLAYBACK_ORIGIN_HOST:-$HAPROXY_PUBLIC_IP}
  2) Enable Token Authentication in BunnyCDN; copy the security key.
  3) Update /opt/streaming-auth/.env:
       BUNNY_TOKEN_KEY=<key from BunnyCDN>
       BUNNY_CDN_URL=https://<your-pullzone>.b-cdn.net
     Then: systemctl restart streaming-auth
═══════════════════════════════════════════════════════════════
EOF
        chmod 600 /root/STREAM_KEYS.txt
        ok "Credentials saved to /root/STREAM_KEYS.txt"
    else
        warn "Keeping existing .env"
    fi

    # Clean up any legacy flat-file deployment from previous versions of this script
    [ -f /opt/streaming-auth/server.js ] && rm -f /opt/streaming-auth/server.js

    chown -R streaming-auth:streaming-auth /opt/streaming-auth
    chmod 640 /opt/streaming-auth/.env
    # Build artifacts must be executable/readable by the service user
    find /opt/streaming-auth/dist -type d -exec chmod 755 {} \; 2>/dev/null || true
    find /opt/streaming-auth/dist -type f -exec chmod 644 {} \; 2>/dev/null || true

    # Systemd unit — hardened (NestJS dist/main.js)
    cat > /etc/systemd/system/streaming-auth.service <<'UNIT_EOF'
[Unit]
Description=Streaming Auth Service (NestJS)
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=streaming-auth
Group=streaming-auth
WorkingDirectory=/opt/streaming-auth
EnvironmentFile=/opt/streaming-auth/.env
ExecStart=/usr/bin/node dist/main.js
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
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
# NOTE: MemoryDenyWriteExecute intentionally omitted — conflicts with V8 JIT
RestrictRealtime=yes
SystemCallArchitectures=native
ReadWritePaths=/opt/streaming-auth

# Logs → journald (rotated by systemd)
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF

    systemctl daemon-reload
    systemctl enable streaming-auth >/dev/null
    systemctl restart streaming-auth
    sleep 2
    systemctl is-active --quiet streaming-auth || err "Auth service failed; journalctl -u streaming-auth"
    ok "Auth service running as streaming-auth user"

    #─── HAProxy config ────────────────────────────────────────────────────────
    log "Configuring HAProxy..."
    [ ! -f /etc/haproxy/haproxy.cfg.bak ] && cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak

    # TLS-related blocks only emitted when TLS is enabled
    local TLS_FRONTEND_HTTP=""
    local TLS_FRONTEND_RTMP=""
    if [ "$ALLOW_NO_TLS" != "1" ]; then
        TLS_FRONTEND_HTTP="
# HTTPS frontend (TLS terminated here; backend is plain HTTP over VPC)
frontend https_in
    bind *:443 ssl crt /etc/haproxy/certs/origin.pem alpn h2,http/1.1
    mode http
    option httplog
    option http-keep-alive
    http-response set-header Strict-Transport-Security \"max-age=31536000; includeSubDomains\"

    acl is_health path /health
    http-request return status 200 content-type text/plain string \"ok\\n\" if is_health

    acl is_options method OPTIONS
    http-request return status 204 hdr \"Access-Control-Allow-Origin\" \"*\" hdr \"Access-Control-Allow-Methods\" \"GET, POST, OPTIONS, HEAD\" hdr \"Access-Control-Allow-Headers\" \"Content-Type, Range, Authorization\" hdr \"Access-Control-Max-Age\" \"86400\" if is_options

    http-response set-header Access-Control-Allow-Origin \"*\"
    http-response set-header Access-Control-Allow-Methods \"GET, POST, OPTIONS, HEAD\"
    http-response set-header Access-Control-Allow-Headers \"Content-Type, Range, Authorization\"

    # Rate limit /sign per-IP at edge (backup to app-level limiter)
    stick-table type ip size 100k expire 60s store http_req_rate(10s)
    http-request track-sc0 src if { path_beg /sign }
    http-request deny deny_status 429 if { path_beg /sign } { sc0_http_req_rate gt 60 }

    acl is_auth_api path_beg /sign
    use_backend auth_service if is_auth_api
    default_backend srs_origin

# RTMPS frontend (OBS push over TLS)
frontend rtmps_in
    bind *:1936 ssl crt ${RTMPS_CERT_PATH}
    mode tcp
    option tcplog
    timeout client 24h
    stick-table type ip size 100k expire 60s store conn_cur,conn_rate(30s)
    tcp-request connection track-sc0 src
    tcp-request connection reject if { sc0_conn_cur ge 5 }
    tcp-request connection reject if { sc0_conn_rate ge 20 }
    default_backend rtmp_origin
"
        TLS_FRONTEND_RTMP="
# Plain RTMP (optional fallback — recommend disabling once publishers are on RTMPS)
frontend rtmp_in
    bind *:1935
    mode tcp
    option tcplog
    timeout client 24h
    stick-table type ip size 100k expire 60s store conn_cur,conn_rate(30s)
    tcp-request connection track-sc0 src
    tcp-request connection reject if { sc0_conn_cur ge 5 }
    tcp-request connection reject if { sc0_conn_rate ge 20 }
    default_backend rtmp_origin
"
    else
        # No-TLS fallback (dev only)
        TLS_FRONTEND_RTMP="
frontend rtmp_in
    bind *:1935
    mode tcp
    option tcplog
    timeout client 24h
    stick-table type ip size 100k expire 60s store conn_cur,conn_rate(30s)
    tcp-request connection track-sc0 src
    tcp-request connection reject if { sc0_conn_cur ge 5 }
    tcp-request connection reject if { sc0_conn_rate ge 20 }
    default_backend rtmp_origin
"
    fi

    # HTTP frontend: redirect 80→443 when TLS on; serve directly when off
    local HTTP_FRONTEND
    if [ "$ALLOW_NO_TLS" != "1" ]; then
        HTTP_FRONTEND="
frontend http_in
    bind *:80
    mode http
    http-request redirect scheme https code 301 unless { path /health }
    acl is_health path /health
    http-request return status 200 content-type text/plain string \"ok\\n\" if is_health
"
    else
        HTTP_FRONTEND="
frontend http_in
    bind *:80
    mode http
    option httplog
    option http-keep-alive

    acl is_health path /health
    http-request return status 200 content-type text/plain string \"ok\\n\" if is_health

    acl is_options method OPTIONS
    http-request return status 204 hdr \"Access-Control-Allow-Origin\" \"*\" hdr \"Access-Control-Allow-Methods\" \"GET, POST, OPTIONS, HEAD\" hdr \"Access-Control-Allow-Headers\" \"Content-Type, Range, Authorization\" hdr \"Access-Control-Max-Age\" \"86400\" if is_options

    http-response set-header Access-Control-Allow-Origin \"*\"
    http-response set-header Access-Control-Allow-Methods \"GET, POST, OPTIONS, HEAD\"
    http-response set-header Access-Control-Allow-Headers \"Content-Type, Range, Authorization\"

    stick-table type ip size 100k expire 60s store http_req_rate(10s)
    http-request track-sc0 src if { path_beg /sign }
    http-request deny deny_status 429 if { path_beg /sign } { sc0_http_req_rate gt 60 }

    acl is_auth_api path_beg /sign
    use_backend auth_service if is_auth_api
    default_backend srs_origin
"
    fi

    cat > /etc/haproxy/haproxy.cfg <<HACFG_EOF
global
    log /dev/log local0 info
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 40000
    nbthread 4
    tune.bufsize 32768
    tune.maxrewrite 8192
    tune.ssl.default-dh-param 2048
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    log global
    option dontlognull
    retries 3
    maxconn 40000
    timeout connect 5s
    timeout client  60s
    timeout server  60s
    timeout tunnel  24h
    timeout http-request 10s
    timeout http-keep-alive 10s
    option redispatch

$HTTP_FRONTEND
$TLS_FRONTEND_HTTP
$TLS_FRONTEND_RTMP

#═══════════════════════════════════════════════════════════
# Backends
#═══════════════════════════════════════════════════════════
backend rtmp_origin
    mode tcp
    option tcp-check
    timeout server 24h
    server origin1 ${SRS_VPC_IP}:1935 check inter 10s rise 2 fall 3

backend srs_origin
    mode http
    option http-keep-alive
    option forwardfor
    http-reuse safe
    timeout connect 3s
    timeout server 30s
    # Cache hints so BunnyCDN can honor origin freshness (Pull Zone →
    # Caching → "Respect origin cache control" should be enabled).
    # Live manifests change every fragment — keep cache very short.
    http-response set-header Cache-Control "public, max-age=1" if { path_end .m3u8 }
    # Segments are immutable once written — aggressive caching is safe.
    http-response set-header Cache-Control "public, max-age=31536000, immutable" if { path_end .ts }
    http-response set-header Cache-Control "public, max-age=31536000, immutable" if { path_end .m4s }
    server origin1 ${SRS_VPC_IP}:8080 check inter 10s rise 2 fall 3 maxconn 1000

backend auth_service
    mode http
    option httpchk GET /health
    http-check expect status 200
    option http-keep-alive
    option forwardfor
    http-reuse safe
    server auth1 ${HAPROXY_VPC_IP}:3000 check inter 5s

#═══════════════════════════════════════════════════════════
# Stats (local only)
#═══════════════════════════════════════════════════════════
listen stats
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /
    stats refresh 5s
    stats admin if LOCALHOST
HACFG_EOF

    haproxy -c -f /etc/haproxy/haproxy.cfg || err "HAProxy config invalid"
    systemctl enable haproxy >/dev/null
    systemctl restart haproxy
    sleep 2
    systemctl is-active --quiet haproxy || err "HAProxy failed; journalctl -u haproxy"
    ok "HAProxy running"

    #─── Kernel tuning ─────────────────────────────────────────────────────────
    cat > /etc/sysctl.d/99-streaming.conf <<'SYSCTL_EOF'
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.ip_local_port_range = 10000 65535
fs.file-max = 2000000
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL_EOF
    sysctl -p /etc/sysctl.d/99-streaming.conf >/dev/null

    #─── Firewall (additive, no reset) ─────────────────────────────────────────
    log "Configuring firewall (additive)..."
    ufw --force enable >/dev/null
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    ufw allow 22/tcp   comment 'SSH'   >/dev/null
    ufw allow 80/tcp   comment 'HTTP'  >/dev/null
    ufw allow 443/tcp  comment 'HTTPS' >/dev/null
    ufw allow 1935/tcp comment 'RTMP'  >/dev/null
    if [ "$ALLOW_NO_TLS" != "1" ]; then
        ufw allow 1936/tcp comment 'RTMPS' >/dev/null
    fi
    ufw allow from "$SRS_VPC_IP" to any port 3000 proto tcp comment 'SRS->auth' >/dev/null
    ok "Firewall rules applied"

    #─── Verification ──────────────────────────────────────────────────────────
    echo ""
    log "Running verification..."
    HEALTH=$(curl -sf -m 3 http://localhost/health 2>/dev/null | tr -d '[:space:]')
    [ "$HEALTH" = "ok" ] && ok "HAProxy HTTP health" || warn "Health check failed"

    AUTH=$(curl -sf -m 3 "http://$HAPROXY_VPC_IP:3000/health" 2>/dev/null || true)
    echo "$AUTH" | grep -q '"status":"ok"' && ok "Auth service health" || warn "Auth failed"

    # /sign without token must return 401
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost/sign \
           -H 'Content-Type: application/json' -d '{"stream":"studio1"}' || true)
    [ "$CODE" = "401" ] && ok "/sign auth enforcement (401 without token)" || warn "/sign returned $CODE, expected 401"

    #─── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  HAPROXY-EDGE SETUP COMPLETE"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Public IP:        $HAPROXY_PUBLIC_IP"
    echo "  Publish host:     ${PUBLISH_HOST:-(not set — ALLOW_NO_TLS mode)}"
    echo "  Playback origin:  ${PLAYBACK_ORIGIN_HOST:-(not set — ALLOW_NO_TLS mode)}"
    echo "  VPC IP:           $HAPROXY_VPC_IP"
    echo "  SRS Origin:       $SRS_VPC_IP"
    echo ""
    echo "  Services:"
    echo "    haproxy:        $(systemctl is-active haproxy)"
    echo "    streaming-auth: $(systemctl is-active streaming-auth) (user: streaming-auth)"
    echo ""
    echo "  Credentials:      /root/STREAM_KEYS.txt (chmod 600)"
    echo "  Logs:             journalctl -u streaming-auth -f"
    echo "                    journalctl -u haproxy -f"
    echo ""
    echo "  Next steps:"
    echo "    1) Run on SRS box:  SRS_API_USER=admin SRS_API_PASS=<from STREAM_KEYS.txt> bash $0 srs"
    echo "    2) Configure BunnyCDN; update .env; systemctl restart streaming-auth"
    echo "    3) OBS publish:   rtmps://${PUBLISH_HOST:-$HAPROXY_PUBLIC_IP}:1936/live"
    echo "═══════════════════════════════════════════════════════════════"
}

#═══════════════════════════════════════════════════════════════════════════════
# SRS ORIGIN SETUP
#═══════════════════════════════════════════════════════════════════════════════
setup_srs() {
    log "Setting up SRS origin (production hardened, pinned to $SRS_VERSION)..."

    #─── Pre-flight ────────────────────────────────────────────────────────────
    ip -4 addr show | grep -q "$SRS_VPC_IP" || err "VPC IP $SRS_VPC_IP not found"
    ok "VPC IP confirmed: $SRS_VPC_IP"

    # SRS API credentials — must be passed in from operator
    local SRS_API_USER="${SRS_API_USER:-}"
    local SRS_API_PASS="${SRS_API_PASS:-}"
    if [ -z "$SRS_API_USER" ] || [ -z "$SRS_API_PASS" ]; then
        err "Export SRS_API_USER and SRS_API_PASS before running (see /root/STREAM_KEYS.txt on haproxy box)"
    fi

    #─── Stop legacy services ──────────────────────────────────────────────────
    if systemctl is-active --quiet nginx-rtmp 2>/dev/null; then
        warn "Stopping old nginx-rtmp"
        systemctl stop nginx-rtmp
        systemctl disable nginx-rtmp
    fi
    if systemctl is-active --quiet nginx 2>/dev/null; then
        warn "Stopping nginx"
        systemctl stop nginx
        systemctl disable nginx
    fi
    pkill -f 'objs/srs' 2>/dev/null || true
    sleep 2

    #─── Dependencies ──────────────────────────────────────────────────────────
    log "Installing build dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y build-essential cmake automake autoconf libtool patch \
        libssl-dev pkg-config git wget curl ufw vnstat htop python3
    ok "Dependencies installed"

    #─── Hostname ──────────────────────────────────────────────────────────────
    hostnamectl set-hostname srs-origin
    grep -q "srs-origin" /etc/hosts || echo "127.0.1.1 srs-origin" >> /etc/hosts

    #─── Dedicated srs user ────────────────────────────────────────────────────
    if ! id srs >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin srs
        ok "Created system user: srs"
    fi

    #─── Build SRS (pinned tag) ────────────────────────────────────────────────
    cd /opt
    if [ ! -d srs ]; then
        log "Cloning SRS at $SRS_VERSION..."
        git clone --depth 1 --branch "$SRS_VERSION" https://github.com/ossrs/srs.git
    else
        cd /opt/srs
        git fetch --tags --depth 1 origin "$SRS_VERSION" || true
        git checkout "$SRS_VERSION" || warn "Could not checkout $SRS_VERSION; using existing tree"
        cd /opt
    fi

    cd /opt/srs/trunk
    # Rebuild when binary is missing OR built with sanitizer (ASan adds ~25% CPU
    # and 2-3x memory; not suitable for production).
    local needs_build=0
    if [ ! -x "objs/srs" ]; then
        needs_build=1
    elif ldd objs/srs 2>/dev/null | grep -q libasan; then
        warn "Existing SRS binary was built with AddressSanitizer; rebuilding without..."
        make clean >/dev/null 2>&1 || true
        needs_build=1
    fi

    if [ "$needs_build" = "1" ]; then
        log "Compiling SRS (5-10 min)..."
        ./configure --sanitizer=off
        make -j"$(nproc)"
        ok "SRS compiled (sanitizer=off)"
    else
        ok "SRS binary exists ($(./objs/srs -v 2>&1 | head -1))"
    fi

    #─── Writable dirs (HLS segments, logs) ────────────────────────────────────
    mkdir -p /opt/srs/trunk/objs/nginx/html
    mkdir -p /var/log/srs
    chown -R srs:srs /opt/srs /var/log/srs

    #─── Production config ─────────────────────────────────────────────────────
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

# HTTP API (protected by basic auth)
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

# HTTP server (HLS, HTTP-FLV)
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
    }

    # Auth callbacks to streaming-auth (over VPC)
    http_hooks {
        enabled         on;
        on_publish      http://${HAPROXY_VPC_IP}:3000/srs/publish;
        on_unpublish    http://${HAPROXY_VPC_IP}:3000/srs/unpublish;
    }

    hls {
        enabled             on;
        hls_path            ./objs/nginx/html;
        hls_fragment        2;
        hls_window          20;
        hls_cleanup         on;
        hls_dispose         30;
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
    ok "Config written"

    # PID dir (tmpfiles so it survives reboot)
    mkdir -p /var/run/srs
    chown srs:srs /var/run/srs
    cat > /etc/tmpfiles.d/srs.conf <<'TMPF_EOF'
d /var/run/srs 0755 srs srs -
TMPF_EOF

    #─── Systemd unit ──────────────────────────────────────────────────────────
    log "Creating systemd service..."
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
# AF_NETLINK required by getifaddrs() — SRS enumerates local interfaces at startup
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

    # Log rotation for /var/log/srs/srs.log
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
    systemctl is-active --quiet srs || err "SRS failed; journalctl -u srs"
    ok "SRS running as srs user"

    #─── Firewall (additive) ───────────────────────────────────────────────────
    log "Configuring firewall (additive)..."
    ufw --force enable >/dev/null
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    ufw allow 22/tcp comment 'SSH' >/dev/null
    ufw allow from "$HAPROXY_VPC_IP" to any port 1935 proto tcp comment 'RTMP from HAProxy' >/dev/null
    ufw allow from "$HAPROXY_VPC_IP" to any port 8080 proto tcp comment 'HTTP from HAProxy' >/dev/null
    ufw allow from "$HAPROXY_VPC_IP" to any port 1985 proto tcp comment 'API from HAProxy' >/dev/null
    ok "Firewall rules applied"

    #─── Verification ──────────────────────────────────────────────────────────
    echo ""
    log "Running verification..."
    ss -tln | grep -q "${SRS_VPC_IP}:1935" && ok "RTMP listening"     || warn "RTMP not listening"
    ss -tln | grep -q "${SRS_VPC_IP}:8080" && ok "HTTP listening"     || warn "HTTP not listening"
    ss -tln | grep -q "${SRS_VPC_IP}:1985" && ok "API listening"      || warn "API not listening"

    # API should reject without auth, accept with auth
    UNAUTH=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://${SRS_VPC_IP}:1985/api/v1/versions" || true)
    [ "$UNAUTH" = "401" ] && ok "SRS API rejects anonymous (401)" || warn "SRS API returned $UNAUTH, expected 401"

    AUTH=$(curl -sf -m 3 -u "${SRS_API_USER}:${SRS_API_PASS}" "http://${SRS_VPC_IP}:1985/api/v1/versions" 2>/dev/null || true)
    echo "$AUTH" | grep -q '"version"' && ok "SRS API authenticated" || warn "SRS API auth failed"

    #─── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  SRS ORIGIN SETUP COMPLETE"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  VPC IP:         $SRS_VPC_IP"
    echo "  HAProxy:        $HAPROXY_VPC_IP"
    echo "  SRS version:    $SRS_VERSION"
    echo "  Running as:     srs (non-root)"
    echo ""
    echo "  Endpoints (VPC only):"
    echo "    RTMP:           $SRS_VPC_IP:1935"
    echo "    HTTP/HLS:       $SRS_VPC_IP:8080"
    echo "    API (authed):   $SRS_VPC_IP:1985"
    echo ""
    echo "  Service:        $(systemctl is-active srs)"
    echo "  Logs:           journalctl -u srs -f"
    echo "                  tail -f /var/log/srs/srs.log  (rotated daily)"
    echo "═══════════════════════════════════════════════════════════════"
}

#═══════════════════════════════════════════════════════════════════════════════
# Main
#═══════════════════════════════════════════════════════════════════════════════
case "$ROLE" in
    haproxy) setup_haproxy ;;
    srs)     setup_srs ;;
    *)       err "Unknown role: $ROLE (use 'haproxy' or 'srs')" ;;
esac
