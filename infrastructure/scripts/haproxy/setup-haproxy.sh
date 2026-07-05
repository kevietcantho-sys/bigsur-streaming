#!/usr/bin/env bash
# =============================================================================
# HAProxy edge — TLS termination, /sign routing to stream-auth, HLS to SRS.
# Idempotent. Re-run safely.
# =============================================================================
#
# Required env vars:
#   HAPROXY_VPC_IP        VPC IP on this box (must be locally bound)
#   SRS_VPC_IP            SRS origin VPC IP
#
# Required for TLS (unless ALLOW_NO_TLS=1):
#   PUBLISH_HOST          OBS ingest hostname (grey-cloud)
#   PLAYBACK_ORIGIN_HOST  BunnyCDN origin hostname (grey-cloud)
#   LETSENCRYPT_EMAIL     Email for the Let's Encrypt SAN cert covering both
#                         hosts. Issued via HTTP-01 — both A-records must
#                         point here and public :80 must be reachable.
#
# Optional:
#   ALLOW_NO_TLS=1        Skip TLS entirely (dev only)
#   STREAM_AUTH_VPC_IP    Backend host for /sign* (default: $HAPROXY_VPC_IP)
#   STREAM_AUTH_PORT      Backend port (default: 3000)
#   BUNNY_EDGE_GUARD      off | monitor | enforce  (default: off)
#   HAPROXY_PUBLIC_IP     Informational
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

HAPROXY_VPC_IP="${HAPROXY_VPC_IP:-}"
SRS_VPC_IP="${SRS_VPC_IP:-}"
HAPROXY_PUBLIC_IP="${HAPROXY_PUBLIC_IP:-}"
PUBLISH_HOST="${PUBLISH_HOST:-}"
PLAYBACK_ORIGIN_HOST="${PLAYBACK_ORIGIN_HOST:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
ALLOW_NO_TLS="${ALLOW_NO_TLS:-0}"
STREAM_AUTH_VPC_IP="${STREAM_AUTH_VPC_IP:-${HAPROXY_VPC_IP}}"
STREAM_AUTH_PORT="${STREAM_AUTH_PORT:-3000}"
BUNNY_EDGE_GUARD="${BUNNY_EDGE_GUARD:-off}"
# Config-only fast path: regenerate + hitless-reload haproxy.cfg without
# touching packages, TLS certs, the bunny refresher, sysctl, or UFW. For
# applying config tweaks (e.g. per-IP conn caps) to an already-provisioned box
# without dropping live publishers. Set via deploy-haproxy-config-remote.sh.
CONFIG_ONLY="${HAPROXY_CONFIG_ONLY:-0}"

arg_required "HAPROXY_VPC_IP" "${HAPROXY_VPC_IP}" "HAPROXY_VPC_IP=<ip>"
arg_required "SRS_VPC_IP"     "${SRS_VPC_IP}"     "SRS_VPC_IP=<ip>"
case "${BUNNY_EDGE_GUARD}" in
    off|monitor|enforce) ;;
    *) die "BUNNY_EDGE_GUARD must be off|monitor|enforce (got: ${BUNNY_EDGE_GUARD})" ;;
esac

if [[ "${ALLOW_NO_TLS}" != "1" ]]; then
    arg_required "PUBLISH_HOST"         "${PUBLISH_HOST}"         "PUBLISH_HOST=<host>"
    arg_required "PLAYBACK_ORIGIN_HOST" "${PLAYBACK_ORIGIN_HOST}" "PLAYBACK_ORIGIN_HOST=<host>"
    arg_required "LETSENCRYPT_EMAIL"    "${LETSENCRYPT_EMAIL}"    "LETSENCRYPT_EMAIL=<email>"
else
    warn "ALLOW_NO_TLS=1 — TLS disabled. DO NOT use in production."
fi

require_local_ip "${HAPROXY_VPC_IP}"

BUNNY_EDGES_LIST=/etc/haproxy/lists/bunny-edges.lst
BUNNY_EDGES_REFRESHER=/usr/local/sbin/refresh-bunny-edges.sh

[[ "${CONFIG_ONLY}" = "1" ]] && log "HAPROXY_CONFIG_ONLY=1 — regenerate + hitless reload of haproxy.cfg only (skipping packages, certs, bunny refresher, sysctl, UFW)"

# --- packages ---------------------------------------------------------------
if [[ "${CONFIG_ONLY}" != "1" ]]; then
    apt_install haproxy certbot ufw curl ca-certificates jq python3

    hostnamectl set-hostname haproxy-edge
    idempotent_append "127.0.1.1 haproxy-edge" /etc/hosts
fi

# --- TLS certs (Let's Encrypt — one SAN cert for :443 HLS + :1936 RTMPS) -----
# CF Origin Certs are only trusted by Cloudflare. PLAYBACK_ORIGIN_HOST is
# grey-cloud (BunnyCDN pulls it directly, CF not in path) so the origin needs
# a publicly-trusted cert. One LE SAN cert covers the HLS origin host and the
# OBS ingest host; HAProxy serves it on both :443 and :1936.
TLS_CERT_PATH=/etc/haproxy/certs/origin.pem
if [[ "${ALLOW_NO_TLS}" != "1" && "${CONFIG_ONLY}" != "1" ]]; then
    mkdir -p /etc/haproxy/certs
    chown root:haproxy /etc/haproxy/certs
    chmod 750 /etc/haproxy/certs

    LE_LIVE="/etc/letsencrypt/live/${PLAYBACK_ORIGIN_HOST}"
    if [[ ! -f "${LE_LIVE}/fullchain.pem" ]]; then
        log "Obtaining Let's Encrypt cert for ${PLAYBACK_ORIGIN_HOST} + ${PUBLISH_HOST} (HTTP-01 on :80)..."
        # Open :80 BEFORE certbot's standalone server runs. bootstrap.sh leaves
        # UFW default-deny incoming, so without this the ACME CA's inbound :80
        # connection is dropped → "Timeout during connect (likely firewall
        # problem)". Idempotent — the UFW section at the end re-asserts it.
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
            ufw allow 80/tcp comment 'HTTP' >/dev/null 2>&1 || true
        fi
        systemctl stop haproxy 2>/dev/null || true
        certbot certonly --standalone --non-interactive --agree-tos \
            -m "${LETSENCRYPT_EMAIL}" \
            --cert-name "${PLAYBACK_ORIGIN_HOST}" \
            -d "${PLAYBACK_ORIGIN_HOST}" -d "${PUBLISH_HOST}" \
            --preferred-challenges http
        ok "Let's Encrypt cert issued"
    else
        ok "Let's Encrypt cert already present"
    fi

    cat "${LE_LIVE}/fullchain.pem" "${LE_LIVE}/privkey.pem" > "${TLS_CERT_PATH}"
    chmod 640 "${TLS_CERT_PATH}"
    chown root:haproxy "${TLS_CERT_PATH}"
    ok "TLS cert at ${TLS_CERT_PATH} (Let's Encrypt — ${PLAYBACK_ORIGIN_HOST}, ${PUBLISH_HOST})"

    # Renewal hooks — stop haproxy for the HTTP-01 challenge, rebuild the
    # combined PEM on deploy, restart.
    mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post,deploy}
    # Drop the stale hook from the old CF-Origin-Cert layout, if present.
    rm -f /etc/letsencrypt/renewal-hooks/deploy/haproxy-publish.sh
    cat > /etc/letsencrypt/renewal-hooks/pre/haproxy-stop.sh <<'PRE_EOF'
#!/bin/bash
systemctl stop haproxy
PRE_EOF
    cat > /etc/letsencrypt/renewal-hooks/post/haproxy-start.sh <<'POST_EOF'
#!/bin/bash
systemctl start haproxy
POST_EOF
    cat > /etc/letsencrypt/renewal-hooks/deploy/haproxy-cert.sh <<HOOK_EOF
#!/bin/bash
set -e
cat /etc/letsencrypt/live/${PLAYBACK_ORIGIN_HOST}/fullchain.pem \\
    /etc/letsencrypt/live/${PLAYBACK_ORIGIN_HOST}/privkey.pem \\
    > ${TLS_CERT_PATH}
chmod 640 ${TLS_CERT_PATH}
chown root:haproxy ${TLS_CERT_PATH}
HOOK_EOF
    chmod +x /etc/letsencrypt/renewal-hooks/pre/haproxy-stop.sh \
             /etc/letsencrypt/renewal-hooks/post/haproxy-start.sh \
             /etc/letsencrypt/renewal-hooks/deploy/haproxy-cert.sh
    ok "Auto-renew hooks installed (deploy → rebuild ${TLS_CERT_PATH})"
fi

# --- BunnyCDN edge IP refresher ---------------------------------------------
install_bunny_edge_refresher() {
    log "Installing BunnyCDN edge IP refresher..."
    mkdir -p /etc/haproxy/lists
    chown root:haproxy /etc/haproxy/lists 2>/dev/null || true
    chmod 750 /etc/haproxy/lists

    cat > "${BUNNY_EDGES_REFRESHER}" <<'REFRESH_EOF'
#!/bin/bash
# Pulls BunnyCDN's published edge-server IP lists, validates and dedupes,
# atomically replaces /etc/haproxy/lists/bunny-edges.lst, reloads HAProxy
# only when the file changed. Installed by setup-haproxy.sh.
set -euo pipefail
LIST_PATH=/etc/haproxy/lists/bunny-edges.lst
LOCK=/run/refresh-bunny-edges.lock
V4_URL="https://api.bunny.net/system/edgeserverlist/plain"
V6_URL="https://api.bunny.net/system/edgeserverlist/IPv6/plain"
MIN_IPS=30

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
exec 9>"$LOCK"; flock -n 9 || { logger -t bunny-edges "another instance running; skip"; exit 0; }

fetch_to() { curl -sSL --fail --max-time 15 --retry 3 --retry-delay 2 -o "$2" "$1"; }

if ! fetch_to "$V4_URL" "$WORK/v4"; then logger -t bunny-edges "ERROR: IPv4 fetch failed"; exit 1; fi
if ! fetch_to "$V6_URL" "$WORK/v6"; then logger -t bunny-edges "WARN: IPv6 fetch failed"; : > "$WORK/v6"; fi

cat "$WORK/v4" "$WORK/v6" | tr -d '\r' | grep -E '^[0-9a-fA-F:./]+$' | awk 'NF' | sort -u > "$WORK/clean"
count=$(wc -l < "$WORK/clean" | tr -d ' ')
if [ "$count" -lt "$MIN_IPS" ]; then
    logger -t bunny-edges "ERROR: only $count IPs (need ≥${MIN_IPS}); keeping existing list"; exit 1
fi
if [ -f "$LIST_PATH" ] && cmp -s "$WORK/clean" "$LIST_PATH"; then
    logger -t bunny-edges "no change ($count IPs)"; exit 0
fi
install -m 0644 -o root -g haproxy "$WORK/clean" "$LIST_PATH.new" 2>/dev/null \
    || install -m 0644 "$WORK/clean" "$LIST_PATH.new"
mv -f "$LIST_PATH.new" "$LIST_PATH"
logger -t bunny-edges "updated: $count IPs; reloading haproxy"
systemctl is-active --quiet haproxy && (systemctl reload haproxy || logger -t bunny-edges "WARN: reload failed")
REFRESH_EOF
    chmod 0755 "${BUNNY_EDGES_REFRESHER}"
    chown root:root "${BUNNY_EDGES_REFRESHER}"

    cat > /etc/cron.d/bunny-edges <<CRON_EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
@reboot      root  sleep 30 && ${BUNNY_EDGES_REFRESHER}
17 * * * *   root  ${BUNNY_EDGES_REFRESHER}
CRON_EOF
    chmod 0644 /etc/cron.d/bunny-edges
    ok "Installed ${BUNNY_EDGES_REFRESHER} + /etc/cron.d/bunny-edges"

    log "Seeding ${BUNNY_EDGES_LIST}..."
    if "${BUNNY_EDGES_REFRESHER}"; then
        [[ -s "${BUNNY_EDGES_LIST}" ]] \
            && ok "Seeded ($(wc -l < "${BUNNY_EDGES_LIST}" | tr -d ' ') IPs)"
    else
        warn "Initial seed failed — cron will retry hourly"
        if [[ ! -f "${BUNNY_EDGES_LIST}" ]]; then
            echo "0.0.0.0/32" > "${BUNNY_EDGES_LIST}"
            chmod 0644 "${BUNNY_EDGES_LIST}"
            warn "Wrote placeholder ${BUNNY_EDGES_LIST}"
        fi
    fi

    if [[ "${BUNNY_EDGE_GUARD}" = "enforce" ]]; then
        [[ -s "${BUNNY_EDGES_LIST}" ]] || die "BUNNY_EDGE_GUARD=enforce but list empty"
        local seeded; seeded=$(wc -l < "${BUNNY_EDGES_LIST}" | tr -d ' ')
        [[ "${seeded}" -lt 30 ]] && die "BUNNY_EDGE_GUARD=enforce but list has only ${seeded} IPs"
    fi
}
[[ "${CONFIG_ONLY}" != "1" ]] && install_bunny_edge_refresher

# --- HAProxy config (rendered from conf/ templates → /etc/haproxy/conf.d) ----
# haproxy.cfg is assembled by concatenating the numbered conf.d fragments in
# lexical order (00-global first so global+defaults precede every proxy). The
# fragment sources are the conf/*.cfg templates next to this script; @TOKEN@
# placeholders are substituted from .env at render time. For fast config-only
# tweaks (no cert / package churn) use deploy-haproxy-config-remote.sh.
CONF_D=/etc/haproxy/conf.d
CONF_SRC="${SCRIPT_DIR}/conf"
[[ -d "${CONF_SRC}" ]] || die "conf/ templates missing at ${CONF_SRC}"

log "Rendering ${CONF_SRC}/*.cfg → ${CONF_D}/*.cfg..."
[[ ! -f /etc/haproxy/haproxy.cfg.bak ]] && cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak 2>/dev/null || true
# Snapshot conf.d so a bad regenerate can roll back before touching the live cfg.
rm -rf "${CONF_D}.bak"
[[ -d "${CONF_D}" ]] && cp -a "${CONF_D}" "${CONF_D}.bak"
rm -rf "${CONF_D}"
mkdir -p "${CONF_D}"

BUNNY_GUARD_DEFS=""
case "${BUNNY_EDGE_GUARD}" in
    monitor)
        BUNNY_GUARD_DEFS="    # BunnyCDN edge allowlist (monitor — log only).
    acl is_bunny_edge src -f ${BUNNY_EDGES_LIST}
    http-request set-log-level alert if !{ path /health } !{ path_beg /sign } !{ method OPTIONS } !is_bunny_edge"
        ;;
    enforce)
        BUNNY_GUARD_DEFS="    # BunnyCDN edge allowlist (enforce — 403 non-Bunny IPs).
    acl is_bunny_edge src -f ${BUNNY_EDGES_LIST}
    http-request deny deny_status 403 if !{ path /health } !{ path_beg /sign } !{ method OPTIONS } !is_bunny_edge"
        ;;
esac

render() { # render <template> <dest-fragment> — substitute @TOKEN@ placeholders
    local content
    content="$(cat "${CONF_SRC}/$1")"
    content="${content//@TLS_CERT_PATH@/${TLS_CERT_PATH}}"
    content="${content//@SRS_VPC_IP@/${SRS_VPC_IP}}"
    content="${content//@STREAM_AUTH_VPC_IP@/${STREAM_AUTH_VPC_IP}}"
    content="${content//@STREAM_AUTH_PORT@/${STREAM_AUTH_PORT}}"
    content="${content//@BUNNY_GUARD_DEFS@/${BUNNY_GUARD_DEFS}}"
    printf '%s\n' "${content}" > "${CONF_D}/$2"
}

render 00-global.cfg 00-global.cfg
render 10-stats.cfg  10-stats.cfg
if [[ "${ALLOW_NO_TLS}" != "1" ]]; then
    render 20-frontend-http.cfg   20-frontend-http.cfg
    render 21-frontend-https.cfg  21-frontend-https.cfg
    render 23-frontend-rtmps.cfg  23-frontend-rtmps.cfg
else
    render 20-frontend-http-notls.cfg 20-frontend-http.cfg
fi
render 22-frontend-rtmp.cfg 22-frontend-rtmp.cfg
render 30-backend-rtmp.cfg  30-backend-rtmp.cfg
render 31-backend-hls.cfg   31-backend-hls.cfg
render 32-backend-auth.cfg  32-backend-auth.cfg

# --- assemble haproxy.cfg from fragments (00-global first) -------------------
cat "${CONF_D}"/*.cfg > /etc/haproxy/haproxy.cfg

if ! haproxy -c -f /etc/haproxy/haproxy.cfg; then
    warn "HAProxy config invalid — rolling back conf.d"
    if [[ -d "${CONF_D}.bak" ]]; then
        rm -rf "${CONF_D}"; mv "${CONF_D}.bak" "${CONF_D}"
        cat "${CONF_D}"/*.cfg > /etc/haproxy/haproxy.cfg 2>/dev/null || true
    fi
    die "HAProxy config invalid"
fi
rm -rf "${CONF_D}.bak"
ok "haproxy.cfg assembled from $(ls -1 "${CONF_D}"/*.cfg | wc -l | tr -d ' ') conf.d fragments"
if [[ "${CONFIG_ONLY}" = "1" ]]; then
    # Hitless reload — keeps live RTMP/RTMPS publishers connected.
    systemctl reload haproxy
    sleep 1
    systemctl is-active --quiet haproxy || die "HAProxy failed; journalctl -u haproxy"
    ok "HAProxy config reloaded (hitless)"
else
    systemctl enable haproxy >/dev/null
    systemctl restart haproxy
    sleep 2
    systemctl is-active --quiet haproxy || die "HAProxy failed; journalctl -u haproxy"
    ok "HAProxy running"
fi

if [[ "${CONFIG_ONLY}" != "1" ]]; then
# --- kernel tuning ----------------------------------------------------------
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
ok "Sysctl tuning applied"

# --- firewall ---------------------------------------------------------------
log "Configuring firewall (additive)..."
ensure_ufw_enabled
ufw allow 22/tcp   comment 'SSH'   >/dev/null
ufw allow 80/tcp   comment 'HTTP'  >/dev/null
ufw allow 443/tcp  comment 'HTTPS' >/dev/null
ufw allow 1935/tcp comment 'RTMP'  >/dev/null
if [[ "${ALLOW_NO_TLS}" != "1" ]]; then
    ufw allow 1936/tcp comment 'RTMPS' >/dev/null
fi
ok "UFW rules applied"
fi

# --- verify -----------------------------------------------------------------
log "Verifying..."
HEALTH=$(curl -sf -m 3 http://localhost/health 2>/dev/null | tr -d '[:space:]')
[[ "${HEALTH}" = "ok" ]] && ok "HAProxy /health" || warn "Health check failed: '${HEALTH}'"

CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost/sign/publish \
       -H 'Content-Type: application/json' -d '{"studio":"studio1"}' || true)
[[ "${CODE}" = "401" ]] \
    && ok "/sign/publish returns 401 without bearer (auth enforced)" \
    || warn "/sign/publish returned ${CODE}, expected 401 — is stream-auth running on ${STREAM_AUTH_VPC_IP}:${STREAM_AUTH_PORT}?"

# --- summary ----------------------------------------------------------------
EDGE_COUNT="(none)"
[[ -s "${BUNNY_EDGES_LIST}" ]] && EDGE_COUNT="$(wc -l < "${BUNNY_EDGES_LIST}" | tr -d ' ') IPs"

cat <<EOF

═══════════════════════════════════════════════════════════════
  HAPROXY EDGE SETUP COMPLETE
═══════════════════════════════════════════════════════════════
  Public IP:        ${HAPROXY_PUBLIC_IP:-<unset>}
  VPC IP:           ${HAPROXY_VPC_IP}
  Publish host:     ${PUBLISH_HOST:-<unset>}
  Playback origin:  ${PLAYBACK_ORIGIN_HOST:-<unset>}
  SRS origin:       ${SRS_VPC_IP}
  Auth backend:     ${STREAM_AUTH_VPC_IP}:${STREAM_AUTH_PORT}

  Bunny edge guard: ${BUNNY_EDGE_GUARD} (${EDGE_COUNT}, refreshed hourly)
                    list:   ${BUNNY_EDGES_LIST}
                    script: ${BUNNY_EDGES_REFRESHER}

  Service:          $(systemctl is-active haproxy)
  Logs:             journalctl -u haproxy -f
                    journalctl -t bunny-edges -f
═══════════════════════════════════════════════════════════════
EOF
