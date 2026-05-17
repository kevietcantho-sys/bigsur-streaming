# `infrastructure/scripts/`

Idempotent deploy scripts for the three boxes that make up the bigsur-streaming
edge: **stream-auth** (NestJS signer), **HAProxy** (TLS edge + Bunny ACL),
**SRS** (LL-HLS origin).

Each component has a pair of scripts:

- `setup-<component>.sh`         — runs **on** the target box (as root)
- `setup-<component>-remote.sh`  — runs **locally**: SSHes in, uploads the
                                   setup script + `common/lib.sh`, executes it,
                                   then cleans up `/tmp`

You normally only invoke the `-remote.sh` wrappers.

## Layout

```
infrastructure/scripts/
├── .env.example                          # copy to .env, edit, source of truth
├── README.md                             # this file
├── common/
│   └── lib.sh                            # shared bash helpers (log/require_root/apt_install/...)
├── stream-auth/
│   ├── setup-stream-auth.sh              # NestJS build + systemd unit, generates .env on first run
│   └── setup-stream-auth-remote.sh       # rsyncs streaming-auth/ source, pulls back /root/STREAM_KEYS.txt
├── haproxy/
│   ├── setup-haproxy.sh                  # haproxy.cfg, TLS, Bunny edge IP refresher (cron)
│   └── setup-haproxy-remote.sh
└── srs/
    ├── setup-srs.sh                      # builds SRS at pinned tag, LL-HLS config, hardened systemd
    └── setup-srs-remote.sh               # has extra -p flag to override SRS_API_PASS
```

## Prerequisites

- **Target boxes**: Ubuntu 22.04 / 24.04 LTS with passwordless `sudo` (or SSH
  in as `root` directly).
- **Local machine**: `bash`, `ssh`, `scp`, `rsync`, `openssl`.
- **HAProxy box**: Cloudflare Origin Cert pre-uploaded to `SSL_CERT_PATH` and
  `SSL_KEY_PATH` (defaults `/etc/ssl/cloudflare/origin.pem` + `.key`). Skip
  with `ALLOW_NO_TLS=1` for dev only.

## Configure once

```bash
cp infrastructure/scripts/.env.example infrastructure/scripts/.env
$EDITOR infrastructure/scripts/.env
```

Required values:

| Var | Meaning |
|-----|---------|
| `HAPROXY_VPC_IP`        | VPC IP of the HAProxy edge box |
| `SRS_VPC_IP`            | VPC IP of the SRS origin box |
| `HAPROXY_PUBLIC_IP`     | Public IP of HAProxy (printed in `STREAM_KEYS.txt`) |
| `PUBLISH_HOST`          | OBS ingest hostname (grey-cloud DNS) |
| `PLAYBACK_ORIGIN_HOST`  | Origin hostname BunnyCDN pulls from |
| `SSL_CERT_PATH` / `SSL_KEY_PATH` | Cloudflare Origin Cert on the HAProxy box |

Optional / advanced:

| Var | Default | Meaning |
|-----|---------|---------|
| `SSH_USER`             | `root`    | SSH user for all wrappers (override per-call with `-u`) |
| `LETSENCRYPT_EMAIL`    | _(unset)_ | If set, HAProxy issues an LE cert for `PUBLISH_HOST` on `:1936` so OBS can do RTMPS |
| `ALLOW_NO_TLS`         | `0`       | `1` skips TLS entirely (dev only) |
| `BUNNY_EDGE_GUARD`     | `off`     | `off` \| `monitor` \| `enforce` — locks HLS pull paths to BunnyCDN edge IPs |
| `STREAM_AUTH_VPC_IP`   | `$HAPROXY_VPC_IP` | Where stream-auth binds. Set when running it on its own VPS. |
| `STREAM_AUTH_PORT`     | `3000`    | Bind port for stream-auth |
| `SRS_API_USER`         | `admin`   | SRS HTTP API basic-auth user |
| `SRS_API_PASS`         | _(auto)_  | Auto-generated on first stream-auth run; flows to SRS via `STREAM_KEYS.txt` snapshot |
| `SRS_VERSION`          | `v6.0-r0` | SRS git tag to build |

## Deploy

Run in this order (each is idempotent — safe to re-run):

```bash
# 1. stream-auth (NestJS signer)
./infrastructure/scripts/stream-auth/setup-stream-auth-remote.sh <stream-auth-ip>
# On first run: generates SIGN_API_TOKEN_DEFAULT, PUBLISH_SIGN_KEY_DEFAULT,
# SRS_API_PASS. Writes /root/STREAM_KEYS.txt on the box and pulls a copy back
# to infrastructure/scripts/.STREAM_KEYS.<host>.txt (chmod 600) for the SRS
# wrapper to consume.

# 2. HAProxy edge (TLS + Bunny ACL + /sign routing)
./infrastructure/scripts/haproxy/setup-haproxy-remote.sh <haproxy-ip>

# 3. SRS origin (LL-HLS)
./infrastructure/scripts/srs/setup-srs-remote.sh <srs-ip>
# SRS_API_PASS auto-recovered from .STREAM_KEYS.*.txt; override with -p <pass>.
```

When stream-auth is colocated with HAProxy (default), steps 1 and 2 target the
same IP.

## Scaling stream-auth to its own VPS

stream-auth is colocated with HAProxy by default but can move to a dedicated
box for horizontal scale, blast-radius isolation, or independent rollouts.

1. Edit `infrastructure/scripts/.env`:
   ```env
   STREAM_AUTH_VPC_IP=<new-vps-vpc-ip>
   ```
2. Re-run all three wrappers, each pointing at the right host:
   ```bash
   ./infrastructure/scripts/stream-auth/setup-stream-auth-remote.sh <stream-auth-ip>
   ./infrastructure/scripts/haproxy/setup-haproxy-remote.sh         <haproxy-ip>
   ./infrastructure/scripts/srs/setup-srs-remote.sh                 <srs-ip>
   ```

The HAProxy `auth_service` backend, SRS `on_publish` / `on_unpublish` hooks,
and UFW rules on all three boxes pick up `STREAM_AUTH_VPC_IP` automatically.
The stream-auth box opens `:3000` from both `$HAPROXY_VPC_IP` (for `/sign/*`)
and `$SRS_VPC_IP` (for `/srs/publish` + `/srs/unpublish`).

## Wrapper flags

All three `-remote.sh` wrappers share:

| Flag      | Meaning |
|-----------|---------|
| `-u USER` | SSH user (override `SSH_USER`; default `root`) |
| `-i FILE` | SSH identity file |
| `-h`      | Help |

`setup-srs-remote.sh` additionally accepts:

| Flag      | Meaning |
|-----------|---------|
| `-p PASS` | Override `SRS_API_PASS` (otherwise read from `.env`, env, or `.STREAM_KEYS.*.txt`) |

Flags must come **before** the host IPs.

## What the scripts write on each box

| Box | Path | Purpose |
|-----|------|---------|
| stream-auth | `/opt/streaming-auth/`                    | App tree (rsynced from `streaming-auth/`) |
| stream-auth | `/opt/streaming-auth/.env`                | Per-tenant secrets, bind IP, SRS API creds |
| stream-auth | `/etc/systemd/system/streaming-auth.service` | Hardened systemd unit |
| stream-auth | `/root/STREAM_KEYS.txt`                   | Credentials snapshot (chmod 600) |
| HAProxy     | `/etc/haproxy/haproxy.cfg`                | Generated config (HTTP/HTTPS/RTMP/RTMPS) |
| HAProxy     | `/etc/haproxy/certs/origin.pem`           | CF Origin Cert (combined) |
| HAProxy     | `/etc/haproxy/certs/publish.pem`          | LE cert for RTMPS (if `LETSENCRYPT_EMAIL` set) |
| HAProxy     | `/usr/local/sbin/refresh-bunny-edges.sh`  | Hourly cron — refreshes Bunny edge IP allowlist |
| HAProxy     | `/etc/haproxy/lists/bunny-edges.lst`      | Current Bunny edge IP list |
| HAProxy     | `/etc/cron.d/bunny-edges`                 | Cron schedule (`@reboot` + `17 * * * *`) |
| SRS         | `/opt/srs/`                               | Built from git at `$SRS_VERSION` |
| SRS         | `/opt/srs/trunk/conf/production.conf`     | LL-HLS config + `on_publish` hooks |
| SRS         | `/etc/systemd/system/srs.service`         | Hardened unit (`AF_NETLINK` allowed for `getifaddrs`) |
| SRS         | `/etc/sysctl.d/99-srs.conf`               | TCP keepalive — kills half-open publishers fast |

Each box also gets additive UFW rules (port 22 always, plus the minimum VPC
allowlists needed for its role).

## Re-running / rotating

All scripts are idempotent:

- **stream-auth** keeps an existing `/opt/streaming-auth/.env`; it only
  generates secrets on the first run. To rotate, edit the file → `systemctl
  restart streaming-auth`. Rotating `PUBLISH_SIGN_KEY_<TENANT>` invalidates
  every live OBS URL for that tenant.
- **HAProxy** rewrites `haproxy.cfg` from current `.env` + flags. The Bunny
  refresher cron stays in place across re-runs.
- **SRS** rewrites `production.conf`; only rebuilds the binary if missing or
  if the existing one was built with ASan.

## Troubleshooting

| Symptom | Where to look |
|---------|---------------|
| `setup-*-remote.sh: SSH failed` | Test `ssh <user>@<host> echo OK` manually; check `-u` / `-i`. |
| `Missing host` | A flag was placed **after** the IP — flags must come first. |
| `SRS_API_PASS missing` running setup-srs-remote | Run stream-auth wrapper first, or pass `-p <pass>` explicitly. |
| `require_local_ip` fails | Wrong host — `STREAM_AUTH_VPC_IP` / `HAPROXY_VPC_IP` / `SRS_VPC_IP` doesn't belong to this box. |
| `BUNNY_EDGE_GUARD=enforce but list has only N IPs` | Initial Bunny fetch failed (≥30 IPs required). Re-run wrapper after fixing egress. |
| stream-auth `/health` not returning ok | `journalctl -u streaming-auth -f` on the box; commonly a malformed `.env` value. |
| SRS publish rejected (`missing signature` / `expired`) | OBS URL needs to come fresh from `POST /sign/publish` — `txTime` is finite. |

For deeper context (architecture, the BunnyCDN signing model, multi-tenant
layout, security posture) see the repo root [`README.md`](../../README.md).
