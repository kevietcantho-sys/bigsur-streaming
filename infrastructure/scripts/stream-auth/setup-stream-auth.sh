#!/usr/bin/env bash
# =============================================================================
# stream-auth (NestJS) — deploy on a target box (typically haproxy-edge)
# Idempotent. Re-run safely: keeps existing .env, refreshes binary + systemd.
# =============================================================================
#
# Required env vars (set in infrastructure/scripts/.env or passed inline):
#   HAPROXY_VPC_IP        Where stream-auth binds by default (colocated)
#   SRS_VPC_IP            For UFW rule: SRS → stream-auth :PORT
#
# Optional:
#   STREAM_AUTH_VPC_IP    Override bind IP (default: $HAPROXY_VPC_IP)
#   STREAM_AUTH_PORT      Bind port (default: 3000)
#   PUBLISH_HOST          Written into .env as PUBLISH_DOMAIN
#   PUBLISH_APP           SRS RTMP app / HLS path segment (default: luckylive)
#   LETSENCRYPT_EMAIL     If set, PUBLISH_RTMPS_ENABLED=true in .env
#   SRS_API_USER          Default: admin
#   SRS_API_PASS          Default: auto-generate on first run
#   HAPROXY_PUBLIC_IP     Informational, printed in STREAM_KEYS.txt
#   PLAYBACK_ORIGIN_HOST  Informational, printed in STREAM_KEYS.txt
#
# Expected layout:
#   <script-dir>/setup-stream-auth.sh   (this file)
#   <script-dir>/lib.sh                 (uploaded by remote wrapper)
#   <script-dir>/streaming-auth/        (source tree rsynced by remote wrapper)
# Falls back to repo layout when run from a checkout:
#   <repo>/infrastructure/scripts/stream-auth/setup-stream-auth.sh
#   <repo>/infrastructure/scripts/common/lib.sh
#   <repo>/streaming-auth/
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate lib.sh: colocated (remote upload) first, repo layout second.
if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    # shellcheck source=/dev/null
    . "${SCRIPT_DIR}/lib.sh"
elif [[ -f "${SCRIPT_DIR}/../common/lib.sh" ]]; then
    # shellcheck source=/dev/null
    . "${SCRIPT_DIR}/../common/lib.sh"
else
    echo "lib.sh not found next to script or at ../common/lib.sh" >&2
    exit 1
fi

# Locate streaming-auth source tree the same way.
if [[ -d "${SCRIPT_DIR}/streaming-auth" ]]; then
    SRC_DIR="${SCRIPT_DIR}/streaming-auth"
elif [[ -d "${SCRIPT_DIR}/../../../streaming-auth" ]]; then
    SRC_DIR="$(cd "${SCRIPT_DIR}/../../../streaming-auth" && pwd)"
else
    die "streaming-auth/ source tree not found (looked next to script and at repo root)"
fi
[[ -f "${SRC_DIR}/package.json" ]] || die "${SRC_DIR}/package.json missing — source tree incomplete"

require_root
require_ubuntu

# --- config -----------------------------------------------------------------
HAPROXY_VPC_IP="${HAPROXY_VPC_IP:-}"
SRS_VPC_IP="${SRS_VPC_IP:-}"
STREAM_AUTH_VPC_IP="${STREAM_AUTH_VPC_IP:-${HAPROXY_VPC_IP}}"
STREAM_AUTH_PORT="${STREAM_AUTH_PORT:-3000}"
PUBLISH_HOST="${PUBLISH_HOST:-}"
PUBLISH_APP="${PUBLISH_APP:-luckylive}"
PLAYBACK_ORIGIN_HOST="${PLAYBACK_ORIGIN_HOST:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
SRS_API_USER="${SRS_API_USER:-admin}"
SRS_API_PASS="${SRS_API_PASS:-}"
HAPROXY_PUBLIC_IP="${HAPROXY_PUBLIC_IP:-}"

arg_required "STREAM_AUTH_VPC_IP" "${STREAM_AUTH_VPC_IP}" "STREAM_AUTH_VPC_IP=<ip> (or HAPROXY_VPC_IP=<ip>)"
require_local_ip "${STREAM_AUTH_VPC_IP}"

APP_DIR=/opt/streaming-auth
ENV_FILE="${APP_DIR}/.env"
KEYS_FILE=/root/STREAM_KEYS.txt

# --- packages ---------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
    log "Installing Node 20 (NodeSource)..."
    apt_install curl ca-certificates
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt_invalidate_cache
    apt_install nodejs
fi
apt_install rsync openssl

ok "Node $(node -v), npm $(npm -v)"

# --- user -------------------------------------------------------------------
if ! id streaming-auth >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin streaming-auth
    ok "Created system user: streaming-auth"
fi

# --- deploy source ----------------------------------------------------------
log "Syncing source: ${SRC_DIR} → ${APP_DIR}"
mkdir -p "${APP_DIR}"
rsync -a --delete \
    --exclude 'node_modules/' \
    --exclude 'dist/' \
    --exclude 'coverage/' \
    --exclude '.env' \
    --exclude '.env.*' \
    --exclude '*.log' \
    "${SRC_DIR}/" "${APP_DIR}/"

log "npm ci (with devDeps for build)..."
( cd "${APP_DIR}" && npm ci --no-audit --no-fund )

log "Building (nest build)..."
( cd "${APP_DIR}" && npm run build )

log "Pruning devDeps..."
( cd "${APP_DIR}" && npm prune --omit=dev --no-audit --no-fund )

# Legacy cleanup: older script wrote a flat server.js
[[ -f "${APP_DIR}/server.js" ]] && rm -f "${APP_DIR}/server.js"

# --- .env -------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
    DEFAULT_TENANT_TOKEN=$(gen_hex 32)
    DEFAULT_TENANT_KEY=$(gen_hex 32)
    [[ -z "${SRS_API_PASS}" ]] && SRS_API_PASS=$(gen_hex 16)

    cat > "${ENV_FILE}" <<EOF
# ═══════════════════════════════════════════════════════════════
# streaming-auth (NestJS) — secrets and env overrides
# Base defaults live in config/default.yaml. Env vars win over YAML.
# ═══════════════════════════════════════════════════════════════

# ── Per-tenant bearer + push key ──────────────────────────────────
# Pattern: SIGN_API_TOKEN_<TENANT>   — bearer for POST /sign/publish
#          PUBLISH_SIGN_KEY_<TENANT> — md5 input for txSecret signing
# <TENANT> is uppercase; the tenant id appears lowercase in stream
# names (<tenant>__<studio>) and URLs.
#
# Every tenant must have BOTH vars set; mismatched pairs fail boot.
# Bootstrap tenant: "default" (rename / add more as you onboard).
SIGN_API_TOKEN_DEFAULT=${DEFAULT_TENANT_TOKEN}
PUBLISH_SIGN_KEY_DEFAULT=${DEFAULT_TENANT_KEY}

# BunnyCDN — playback signing moved to clients (each tenant holds its own
# pull zone + token key). Reference signer at src/modules/sign/bunny.service.ts.
BUNNY_TOKEN_KEY=
BUNNY_CDN_URL=

# Publish URL signing (txSecret/txTime).
PUBLISH_DOMAIN=${PUBLISH_HOST}
PUBLISH_APP=${PUBLISH_APP}
PUBLISH_RTMPS_ENABLED=${LETSENCRYPT_EMAIL:+true}
PUBLISH_RTMPS_PORT=1936

# SRS API basic auth (used by monitoring; set same values on SRS box).
SRS_API_USER=${SRS_API_USER}
SRS_API_PASS=${SRS_API_PASS}

# Bind
PORT=${STREAM_AUTH_PORT}
BIND_IP=${STREAM_AUTH_VPC_IP}

# Upstream SRS (informational)
ORIGIN_HOST=${SRS_VPC_IP}
ORIGIN_PORT=8080

# Logging
LOG_LEVEL=info
LOG_FORMAT=json

NODE_ENV=production
EOF
    chmod 640 "${ENV_FILE}"
    ok "Wrote new ${ENV_FILE}"
else
    warn "Keeping existing ${ENV_FILE}"
    # Read existing values to keep STREAM_KEYS.txt in sync.
    DEFAULT_TENANT_TOKEN="$(env_get "${ENV_FILE}" SIGN_API_TOKEN_DEFAULT)"
    DEFAULT_TENANT_KEY="$(env_get "${ENV_FILE}" PUBLISH_SIGN_KEY_DEFAULT)"
    SRS_API_PASS="$(env_get "${ENV_FILE}" SRS_API_PASS)"
    : "${DEFAULT_TENANT_TOKEN:=<missing-in-env>}"
    : "${DEFAULT_TENANT_KEY:=<missing-in-env>}"
    : "${SRS_API_PASS:=<missing-in-env>}"
fi

chown -R streaming-auth:streaming-auth "${APP_DIR}"
chmod 640 "${ENV_FILE}"
find "${APP_DIR}/dist" -type d -exec chmod 755 {} \; 2>/dev/null || true
find "${APP_DIR}/dist" -type f -exec chmod 644 {} \; 2>/dev/null || true

# --- STREAM_KEYS.txt --------------------------------------------------------
cat > "${KEYS_FILE}" <<EOF
═══════════════════════════════════════════════════════════════
  STREAM INFRASTRUCTURE CREDENTIALS — Generated $(date)
  Server: $(hostname) (${HAPROXY_PUBLIC_IP:-<unset>})
  KEEP THIS FILE PRIVATE. chmod 600.

  === OBS PUBLISHER ===
  Backend calls POST /sign/publish (with the tenant's bearer) to mint:
    rtmp://${PUBLISH_HOST:-${HAPROXY_PUBLIC_IP:-<haproxy-ip>}}/luckylive/<tenant>__<studio>?txSecret=<md5>&txTime=<hex>

  === BACKEND → AUTH API ===
  Publish sign:    POST https://${PLAYBACK_ORIGIN_HOST:-<origin-host>}/sign/publish
                   body: {"studio":"<studio>","expires_in":2592000}
                   header: Authorization: Bearer <SIGN_API_TOKEN_OF_THAT_TENANT>

  Bootstrap tenant ("default") credentials:
    SIGN_API_TOKEN_DEFAULT   = ${DEFAULT_TENANT_TOKEN}
    PUBLISH_SIGN_KEY_DEFAULT = ${DEFAULT_TENANT_KEY}

  Add tenants by appending more SIGN_API_TOKEN_<NAME> + PUBLISH_SIGN_KEY_<NAME>
  pairs to ${ENV_FILE} then 'systemctl restart streaming-auth'.

  === SRS HTTP API (internal monitoring) ===
  User: ${SRS_API_USER}
  Pass: ${SRS_API_PASS}
  Pass these to setup-srs.sh on the SRS box.

  === NEXT STEPS ===
  1) Create one BunnyCDN pull zone per tenant. Origin URL:
       https://${PLAYBACK_ORIGIN_HOST:-<origin-host>}
  2) Enable Token Authentication on each pull zone and hand the
     Authentication Key + pull-zone hostname to that tenant.
═══════════════════════════════════════════════════════════════
EOF
chmod 600 "${KEYS_FILE}"
ok "Credentials written to ${KEYS_FILE}"

# --- systemd unit -----------------------------------------------------------
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
# MemoryDenyWriteExecute intentionally omitted — conflicts with V8 JIT
RestrictRealtime=yes
SystemCallArchitectures=native
ReadWritePaths=/opt/streaming-auth

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable streaming-auth >/dev/null
systemctl restart streaming-auth
sleep 2
systemctl is-active --quiet streaming-auth \
    || die "streaming-auth failed; check 'journalctl -u streaming-auth'"
ok "streaming-auth running"

# --- firewall (additive) ----------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
    ensure_ufw_enabled
    ufw allow 22/tcp comment 'SSH' >/dev/null
    if [[ -n "${SRS_VPC_IP}" ]]; then
        ufw allow from "${SRS_VPC_IP}" to any port "${STREAM_AUTH_PORT}" proto tcp \
            comment 'SRS->stream-auth hooks' >/dev/null
    fi
    # When stream-auth is split off to its own VPS, HAProxy reaches it from a
    # different VPC IP for /sign/* — open that path too. Idempotent if same IP.
    if [[ -n "${HAPROXY_VPC_IP}" && "${HAPROXY_VPC_IP}" != "${STREAM_AUTH_VPC_IP}" ]]; then
        ufw allow from "${HAPROXY_VPC_IP}" to any port "${STREAM_AUTH_PORT}" proto tcp \
            comment 'HAProxy->stream-auth /sign' >/dev/null
    fi
    ok "UFW rule for stream-auth :${STREAM_AUTH_PORT} ensured"
fi

# --- verify -----------------------------------------------------------------
log "Verifying /health..."
HEALTH=$(curl -sf -m 3 "http://${STREAM_AUTH_VPC_IP}:${STREAM_AUTH_PORT}/health" 2>/dev/null || true)
echo "${HEALTH}" | grep -q '"status":"ok"' \
    && ok "stream-auth /health OK" \
    || warn "stream-auth /health unexpected: ${HEALTH}"

# --- summary ----------------------------------------------------------------
cat <<EOF

═══════════════════════════════════════════════════════════════
  STREAM-AUTH SETUP COMPLETE
═══════════════════════════════════════════════════════════════
  Binding:        ${STREAM_AUTH_VPC_IP}:${STREAM_AUTH_PORT}
  App dir:        ${APP_DIR}
  Env file:       ${ENV_FILE}
  Credentials:    ${KEYS_FILE} (chmod 600)
  Service:        $(systemctl is-active streaming-auth)
  Logs:           journalctl -u streaming-auth -f

  Next:
    1) Run setup-haproxy.sh on this box (or wherever HAProxy lives).
       HAProxy backend points at ${STREAM_AUTH_VPC_IP}:${STREAM_AUTH_PORT}.
    2) Run setup-srs.sh on the SRS box; pass:
         SRS_API_USER=${SRS_API_USER}
         SRS_API_PASS=${SRS_API_PASS}
═══════════════════════════════════════════════════════════════
EOF
