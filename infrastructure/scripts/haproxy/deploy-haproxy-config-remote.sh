#!/usr/bin/env bash
# =============================================================================
# Deploy haproxy.cfg ONLY — fast, hitless config apply.
# =============================================================================
#
# Thin wrapper over setup-haproxy-remote.sh that sets HAPROXY_CONFIG_ONLY=1.
# On the target box, setup-haproxy.sh then regenerates /etc/haproxy/haproxy.cfg
# from the current .env, validates it (`haproxy -c`), and does a HITLESS
# `systemctl reload` — WITHOUT touching packages, TLS certs, the bunny edge
# refresher, sysctl, or UFW, and WITHOUT dropping live RTMP/RTMPS publishers.
#
# Use this to roll out config-value changes (e.g. the per-IP `sc0_conn_cur`
# ingest connection cap) to an already-provisioned edge. For first-time setup,
# cert issuance, or infra changes, use setup-haproxy-remote.sh instead.
#
# Usage (identical flags/args to setup-haproxy-remote.sh):
#   ./deploy-haproxy-config-remote.sh [OPTIONS] <host> [host-2] ...
#
#   -u USER       SSH user (default: root or a passwordless sudoer)
#   -i IDENTITY   SSH identity file
#   -h            Help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export HAPROXY_CONFIG_ONLY=1
exec "${SCRIPT_DIR}/setup-haproxy-remote.sh" "$@"
