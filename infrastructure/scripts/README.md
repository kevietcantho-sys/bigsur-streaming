# `infrastructure/scripts/`

Idempotent deploy scripts for the three boxes that make up the bigsur-streaming
edge: **stream-auth** (NestJS signer), **HAProxy** (TLS edge + Bunny ACL),
**SRS** (LL-HLS origin).

Each component has a pair of scripts:

- `setup-<component>.sh`         — runs **on** the target box as root (directly,
                                   or via `sudo -E` when deployed by a non-root
                                   sudo user)
- `setup-<component>-remote.sh`  — runs **locally**: SSHes in, uploads the
                                   setup script + `common/lib.sh`, executes it,
                                   then cleans up `/tmp`

You normally only invoke the `-remote.sh` wrappers. On a brand-new box, run
`common/bootstrap-remote.sh` once first (creates a non-root sudo user); after
that, deploy as either `root` or that user.

## Layout

```
infrastructure/scripts/
├── .env.example                          # copy to .env, edit, source of truth
├── README.md                             # this file
├── common/
│   ├── lib.sh                            # shared bash helpers (log/require_root/apt_install/...)
│   ├── bootstrap.sh                      # runs ON a fresh box (as root): creates the non-root sudo user, SSH keys, hardening, UFW
│   └── bootstrap-remote.sh               # runs LOCALLY: SSHes as root, uploads + executes bootstrap.sh
├── stream-auth/
│   ├── setup-stream-auth.sh              # NestJS build + systemd unit, generates .env on first run
│   └── setup-stream-auth-remote.sh       # rsyncs streaming-auth/ source, pulls back STREAM_KEYS.txt from the SSH user's home
├── haproxy/
│   ├── setup-haproxy.sh                  # haproxy.cfg, TLS, Bunny edge IP refresher (cron)
│   └── setup-haproxy-remote.sh
└── srs/
    ├── setup-srs.sh                      # builds SRS at pinned tag, LL-HLS config, hardened systemd
    └── setup-srs-remote.sh               # has extra -p flag to override SRS_API_PASS
```

## Prerequisites

- **Target boxes**: Ubuntu 22.04 / 24.04 LTS. Either SSH in as `root` directly,
  or run `common/bootstrap-remote.sh` first (step 0 below) to create a non-root
  user with passwordless `sudo`, then deploy as that user with `-u <user>`.
- **Local machine**: `bash`, `ssh`, `scp`, `rsync`, `openssl`.
- **HAProxy box**: public port 80 reachable, with the `PUBLISH_HOST` and
  `PLAYBACK_ORIGIN_HOST` A-records pointed at it — `setup-haproxy.sh` issues a
  Let's Encrypt SAN cert over HTTP-01. Skip with `ALLOW_NO_TLS=1` for dev only.

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
| `PLAYBACK_ORIGIN_HOST`  | Origin hostname BunnyCDN pulls from (grey-cloud DNS) |
| `LETSENCRYPT_EMAIL`     | Email for the Let's Encrypt SAN cert (HTTP-01 on :80) |

Optional / advanced:

| Var | Default | Meaning |
|-----|---------|---------|
| `SSH_USER`             | `root`    | SSH user for all wrappers (override per-call with `-u`) |
| `ALLOW_NO_TLS`         | `0`       | `1` skips TLS entirely (dev only) |
| `BUNNY_EDGE_GUARD`     | `off`     | `off` \| `monitor` \| `enforce` — locks HLS pull paths to BunnyCDN edge IPs |
| `STREAM_AUTH_VPC_IP`   | `$HAPROXY_VPC_IP` | Where stream-auth binds. Set when running it on its own VPS. |
| `STREAM_AUTH_PORT`     | `3000`    | Bind port for stream-auth |
| `SRS_API_USER`         | `admin`   | SRS HTTP API basic-auth user |
| `SRS_API_PASS`         | _(auto)_  | Auto-generated on first stream-auth run; flows to SRS via `STREAM_KEYS.txt` snapshot |
| `SRS_VERSION`          | `v6.0-r0` | SRS git tag to build |

Bootstrap config (only used by `common/bootstrap-remote.sh`, step 0 — skip if
you SSH in as root):

| Var | Default | Meaning |
|-----|---------|---------|
| `NEW_USER`             | `deploy`              | Non-root sudo user bootstrap creates; then deploy with `-u $NEW_USER` |
| `VPC_SUBNET`           | `10.40.96.0/20`       | CIDR that SSH (22/tcp) is allowed from after bootstrap enables UFW |
| `BASTION_CIDR`         | _(empty)_             | Extra operator/bastion CIDR allowed to SSH (set when bootstrapping over the public internet) |
| `TIMEZONE`             | `Asia/Ho_Chi_Minh`    | Timezone applied to the box |
| `TAILSCALE_AUTH_KEY`   | _(empty)_             | Set to install Tailscale and join the tailnet; empty = skip |
| `TAILSCALE_TAGS`       | _(empty)_             | Tailscale ACL tags, e.g. `tag:service,tag:production` |
| `SKIP_TAILSCALE`       | `0`                   | `1` skips Tailscale for a node without unsetting the shared key |

## Deploy

Run in this order (each is idempotent — safe to re-run):

```bash
# 0. (optional) Bootstrap a fresh box: create the non-root sudo user.
#    Skip if you SSH in as root and keep SSH_USER=root.
./infrastructure/scripts/common/bootstrap-remote.sh <host> [host-2] ...
# Creates $NEW_USER with passwordless sudo, copies root's SSH keys, hardens
# SSH (no root login / no password auth), enables UFW allowing SSH only from
# $VPC_SUBNET (+ $BASTION_CIDR if set). After this, set SSH_USER=$NEW_USER in
# .env (or pass -u $NEW_USER to each wrapper).
#
#   Bootstrapping over the public internet (not from inside the VPC)? Pass your
#   operator IP or UFW will refuse to enable and lock you out:
#     ./infrastructure/scripts/common/bootstrap-remote.sh -b <your-ip>/32 <host>

# If you ran step 0, deploy as that sudo user: add `-u $NEW_USER` to each
# wrapper (or set SSH_USER=$NEW_USER in .env). The wrappers prefix `sudo -E`
# remotely when the SSH user isn't root.

# 1. stream-auth (NestJS signer)
./infrastructure/scripts/stream-auth/setup-stream-auth-remote.sh <stream-auth-ip>
# On first run: generates SIGN_API_TOKEN_DEFAULT, PUBLISH_SIGN_KEY_DEFAULT,
# SRS_API_PASS. Writes STREAM_KEYS.txt into the SSH user's home on the box
# (~/STREAM_KEYS.txt, owned by that user, chmod 600 — /root when SSH'd as root)
# and pulls a copy back to infrastructure/scripts/.STREAM_KEYS.<host>.txt for
# the SRS wrapper to consume. No sudo needed for the pull-back.

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
| `-u USER` | SSH user (override `SSH_USER`; default `root`). Use the bootstrap'd sudo user (`-u $NEW_USER`) when not SSHing as root — the wrapper adds `sudo -E` remotely. Requires passwordless sudo. |
| `-i FILE` | SSH identity file |
| `-h`      | Help |

`setup-srs-remote.sh` additionally accepts:

| Flag      | Meaning |
|-----------|---------|
| `-p PASS` | Override `SRS_API_PASS` (otherwise read from `.env`, env, or `.STREAM_KEYS.*.txt`) |

Flags must come **before** the host IPs.

`common/bootstrap-remote.sh` always connects as `root` (the box has no other
user yet) and takes its own flags:

| Flag      | Meaning |
|-----------|---------|
| `-u USER` | Non-root sudo user to create (override `NEW_USER`) |
| `-s CIDR` | VPC subnet SSH is allowed from (override `VPC_SUBNET`) |
| `-b CIDR` | Extra operator/bastion CIDR allowed to SSH (override `BASTION_CIDR`) |
| `-z TZ`   | Timezone (override `TIMEZONE`) |
| `-k KEY`  | Tailscale auth key — enables Tailscale (override `TAILSCALE_AUTH_KEY`) |
| `-t TAGS` | Tailscale tags (override `TAILSCALE_TAGS`) |
| `-T`      | Skip Tailscale for this run |
| `-h`      | Help |

## What the scripts write on each box

| Box | Path | Purpose |
|-----|------|---------|
| all (bootstrap) | `/home/$NEW_USER/.ssh/authorized_keys` | Root's SSH keys copied to the new sudo user |
| all (bootstrap) | `/etc/sudoers.d/$NEW_USER`                | Passwordless sudo for the new user |
| all (bootstrap) | `/etc/bigsur/bootstrap.env`               | `NEW_USER` / `VPC_SUBNET` / `BASTION_CIDR` / `TIMEZONE` for later scripts |
| stream-auth | `/opt/streaming-auth/`                    | App tree (rsynced from `streaming-auth/`) |
| stream-auth | `/opt/streaming-auth/.env`                | Per-tenant secrets, bind IP, SRS API creds |
| stream-auth | `/etc/systemd/system/streaming-auth.service` | Hardened systemd unit |
| stream-auth | `~SSH_USER/STREAM_KEYS.txt`               | Credentials snapshot in the deploy user's home (chmod 600, owned by them; `/root` when run as root) |
| HAProxy     | `/etc/haproxy/haproxy.cfg`                | Generated config (HTTP/HTTPS/RTMP/RTMPS) |
| HAProxy     | `/etc/haproxy/certs/origin.pem`           | Let's Encrypt SAN cert — combined fullchain+key, served on `:443` + `:1936` |
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
| bootstrap `Aborted: SSH source is not allowed` | Your SSH client IP isn't in `VPC_SUBNET`/`BASTION_CIDR`; UFW refused to enable to avoid locking you out. Re-run with `-b <your-ip>/32`. |
| SSH as `$NEW_USER` fails right after bootstrap | UFW blocked the source IP (not in `VPC_SUBNET`/`BASTION_CIDR`). Fix `.env`/`-b` and re-run; root over the VPC still works. |
| `Could not pull STREAM_KEYS.txt` | Run as a user whose home holds the file — i.e. the same `-u <user>` used for the stream-auth run (or root). Needs passwordless sudo for the run itself. |
| `setup-*-remote.sh: SSH failed` | Test `ssh <user>@<host> echo OK` manually; check `-u` / `-i`. |
| `Missing host` | A flag was placed **after** the IP — flags must come first. |
| `SRS_API_PASS missing` running setup-srs-remote | Run stream-auth wrapper first, or pass `-p <pass>` explicitly. |
| `require_local_ip` fails | Wrong host — `STREAM_AUTH_VPC_IP` / `HAPROXY_VPC_IP` / `SRS_VPC_IP` doesn't belong to this box. |
| `BUNNY_EDGE_GUARD=enforce but list has only N IPs` | Initial Bunny fetch failed (≥30 IPs required). Re-run wrapper after fixing egress. |
| stream-auth `/health` not returning ok | `journalctl -u streaming-auth -f` on the box; commonly a malformed `.env` value. |
| SRS publish rejected (`missing signature` / `expired`) | OBS URL needs to come fresh from `POST /sign/publish` — `txTime` is finite. |

For deeper context (architecture, the BunnyCDN signing model, multi-tenant
layout, security posture) see the repo root [`README.md`](../../README.md).
