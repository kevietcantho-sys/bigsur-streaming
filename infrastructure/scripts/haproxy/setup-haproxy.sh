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

# --- packages ---------------------------------------------------------------
apt_install haproxy certbot ufw curl ca-certificates jq python3

hostnamectl set-hostname haproxy-edge
idempotent_append "127.0.1.1 haproxy-edge" /etc/hosts

# --- TLS certs (Let's Encrypt — one SAN cert for :443 HLS + :1936 RTMPS) -----
# CF Origin Certs are only trusted by Cloudflare. PLAYBACK_ORIGIN_HOST is
# grey-cloud (BunnyCDN pulls it directly, CF not in path) so the origin needs
# a publicly-trusted cert. One LE SAN cert covers the HLS origin host and the
# OBS ingest host; HAProxy serves it on both :443 and :1936.
TLS_CERT_PATH=/etc/haproxy/certs/origin.pem
if [[ "${ALLOW_NO_TLS}" != "1" ]]; then
    mkdir -p /etc/haproxy/certs
    chown root:haproxy /etc/haproxy/certs
    chmod 750 /etc/haproxy/certs

    LE_LIVE="/etc/letsencrypt/live/${PLAYBACK_ORIGIN_HOST}"
    if [[ ! -f "${LE_LIVE}/fullchain.pem" ]]; then
        log "Obtaining Let's Encrypt cert for ${PLAYBACK_ORIGIN_HOST} + ${PUBLISH_HOST} (HTTP-01 on :80)..."
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
install_bunny_edge_refresher

# --- HAProxy config ---------------------------------------------------------
log "Writing /etc/haproxy/haproxy.cfg..."
[[ ! -f /etc/haproxy/haproxy.cfg.bak ]] && cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak 2>/dev/null || true

BUNNY_GUARD_DEFS=""
case "${BUNNY_EDGE_GUARD}" in
    monitor)
        BUNNY_GUARD_DEFS="
    # BunnyCDN edge allowlist (monitor — log only).
    acl is_bunny_edge src -f ${BUNNY_EDGES_LIST}
    http-request set-log-level alert if !{ path /health } !{ path_beg /sign } !{ method OPTIONS } !is_bunny_edge
"
        ;;
    enforce)
        BUNNY_GUARD_DEFS="
    # BunnyCDN edge allowlist (enforce — 403 non-Bunny IPs).
    acl is_bunny_edge src -f ${BUNNY_EDGES_LIST}
    http-request deny deny_status 403 if !{ path /health } !{ path_beg /sign } !{ method OPTIONS } !is_bunny_edge
"
        ;;
esac

TLS_FRONTEND_HTTP=""
TLS_FRONTEND_RTMP=""
HTTP_FRONTEND=""
if [[ "${ALLOW_NO_TLS}" != "1" ]]; then
    TLS_FRONTEND_HTTP="
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

    # CORS only for HLS playback paths — /sign is a bearer-authed
    # backend-to-backend API and needs no cross-origin exposure.
    http-response set-header Access-Control-Allow-Origin \"*\" if !{ path_beg /sign }
    http-response set-header Access-Control-Allow-Methods \"GET, POST, OPTIONS, HEAD\" if !{ path_beg /sign }
    http-response set-header Access-Control-Allow-Headers \"Content-Type, Range, Authorization\" if !{ path_beg /sign }

    stick-table type ip size 100k expire 60s store http_req_rate(10s)
    http-request track-sc0 src if { path_beg /sign }
    http-request deny deny_status 429 if { path_beg /sign } { sc0_http_req_rate gt 60 }
${BUNNY_GUARD_DEFS}
    acl is_auth_api path_beg /sign
    use_backend auth_service if is_auth_api
    default_backend srs_origin

frontend rtmps_in
    bind *:1936 ssl crt ${TLS_CERT_PATH}
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
    HTTP_FRONTEND="
frontend http_in
    bind *:80
    mode http
    http-request redirect scheme https code 301 unless { path /health }
    acl is_health path /health
    http-request return status 200 content-type text/plain string \"ok\\n\" if is_health
"
else
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

    # CORS only for HLS playback paths — /sign is a bearer-authed
    # backend-to-backend API and needs no cross-origin exposure.
    http-response set-header Access-Control-Allow-Origin \"*\" if !{ path_beg /sign }
    http-response set-header Access-Control-Allow-Methods \"GET, POST, OPTIONS, HEAD\" if !{ path_beg /sign }
    http-response set-header Access-Control-Allow-Headers \"Content-Type, Range, Authorization\" if !{ path_beg /sign }

    stick-table type ip size 100k expire 60s store http_req_rate(10s)
    http-request track-sc0 src if { path_beg /sign }
    http-request deny deny_status 429 if { path_beg /sign } { sc0_http_req_rate gt 60 }
${BUNNY_GUARD_DEFS}
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

${HTTP_FRONTEND}
${TLS_FRONTEND_HTTP}
${TLS_FRONTEND_RTMP}

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
    http-response set-header Cache-Control "public, max-age=1" if { path_end .m3u8 }
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
    server auth1 ${STREAM_AUTH_VPC_IP}:${STREAM_AUTH_PORT} check inter 5s

listen stats
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /
    stats refresh 5s
    stats admin if LOCALHOST
HACFG_EOF

haproxy -c -f /etc/haproxy/haproxy.cfg || die "HAProxy config invalid"
systemctl enable haproxy >/dev/null
systemctl restart haproxy
sleep 2
systemctl is-active --quiet haproxy || die "HAProxy failed; journalctl -u haproxy"
ok "HAProxy running"

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
