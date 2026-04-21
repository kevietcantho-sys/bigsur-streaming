# bigsur-streaming

Production-hardened live streaming infrastructure: **OBS → HAProxy (TLS edge) → SRS (LL-HLS origin) → BunnyCDN → Viewer**.

Two-server bootstrap via a single shell script, plus a browser test player with adaptive latency modes.

---

## Architecture

```
                           ┌──────────────────────────┐
   OBS ─ RTMPS:1936 ─────▶ │ haproxy-edge             │ ─ RTMP:1935 ─▶ SRS (VPC)
                           │ • TLS termination        │
                           │ • Let's Encrypt          │
   Viewer ─ HTTPS:443 ─▶ CDN ─▶ │ • streaming-auth (Node)   │ ─ HTTP:8080 ─▶ SRS /live/*.m3u8
   (BunnyCDN signed URL)    │ • Per-IP rate limiting   │
                           └──────────────────────────┘
                                                              ┌──────────────────┐
                                                              │ srs-origin       │
                                                              │ • LL-HLS (2s)    │
                                                              │ • HTTP-FLV       │
                                                              │ • publish hooks  │
                                                              └──────────────────┘
```

- **Ingest**: RTMPS on `:1936` (TLS) → HAProxy forwards plain RTMP over VPC to SRS `:1935`.
- **Playback**: Viewer hits BunnyCDN; CDN pulls LL-HLS from HAProxy `:443` → SRS `:8080` over VPC.
- **Auth**:
  - Publishers: SRS calls `streaming-auth /srs/publish` to validate per-stream `?key=`.
  - Viewers: backend calls `POST /sign` (Bearer token) → returns BunnyCDN signed URL.

---

## Repo contents

| Path | Purpose |
|------|---------|
| `setup-streaming-infra.sh` | Idempotent setup script — run once per box with role `haproxy` or `srs`. |
| `streaming-auth/` | NestJS auth service (SRS publish hooks + BunnyCDN URL signing). |
| `test.html` | Standalone hls.js player with Low-latency / Balanced / Stable modes + live stats. |
| `BunnyCDN-Auth-Production-Guide.docx` | Operator guide for BunnyCDN Token Authentication setup. |
| `CLAUDE.md` | Claude Code agent instructions (workflows/rules). |

### `streaming-auth/` layout

```
streaming-auth/
├── config/default.yaml          # non-secret defaults (ports, limits, regex)
├── src/
│   ├── main.ts                  # bootstrap (trust proxy, CORS, shutdown hooks)
│   ├── app.module.ts            # wires config + logger + throttler + modules
│   ├── config/                  # YAML loader + zod schema + typed service
│   ├── common/                  # ApiTokenGuard, ZodValidationPipe, filters
│   └── modules/
│       ├── health/              # GET  /health
│       ├── streams/             # POST /srs/publish, /srs/unpublish (VPC-only)
│       │   ├── stream-keys.repository.ts      # interface (DB-ready)
│       │   └── env-stream-keys.repository.ts  # current impl — STREAM_KEYS env
│       └── sign/                # POST /sign (Bearer guard + rate limited)
│           ├── bunny.service.ts # md5 token minting (BunnyCDN spec)
│           └── dto/             # zod request schemas
└── test/app.e2e-spec.ts         # supertest coverage for all 4 routes
```

---

## Prerequisites

- Two Ubuntu servers in the same VPC (Vultr / DO / equivalent).
- Root SSH on both.
- Domain A record → HAProxy public IP (required for TLS).
- BunnyCDN pull zone + Token Authentication enabled (configure after haproxy setup).

Defaults (override with env vars):

| Var | Default |
|-----|---------|
| `HAPROXY_VPC_IP` | `10.40.96.3` |
| `SRS_VPC_IP` | `10.40.96.4` |
| `HAPROXY_PUBLIC_IP` | `45.76.145.205` |
| `DOMAIN` | _(required)_ |
| `LETSENCRYPT_EMAIL` | _(required)_ |
| `ALLOW_NO_TLS` | `0` — set `1` for dev only |

---

## Deploy

The setup script expects the **whole repo** on the HAProxy box so it can rsync + build `streaming-auth/` in place.

### 1. HAProxy edge

```bash
# Sync repo to the box (excludes local builds/secrets)
rsync -a --exclude node_modules --exclude dist --exclude .env \
  ./ root@<haproxy-ip>:/root/bigsur-streaming/

ssh root@<haproxy-ip>
cd /root/bigsur-streaming
DOMAIN=stream.example.com \
LETSENCRYPT_EMAIL=ops@example.com \
bash setup-streaming-infra.sh haproxy
```

The script will:
1. Install Node 20, HAProxy, certbot, rsync.
2. Issue a Let's Encrypt cert for `$DOMAIN`.
3. Copy `streaming-auth/` → `/opt/streaming-auth/`, run `npm ci && npm run build && npm prune --omit=dev`.
4. Generate `/opt/streaming-auth/.env` with random `SIGN_API_TOKEN`, stream keys, SRS API creds.
5. Install the `streaming-auth.service` systemd unit (running `node dist/main.js`).
6. Write HAProxy config with TLS, rate limits, CORS, and `/sign` + SRS backend routing.

Generates credentials at `/root/STREAM_KEYS.txt` (chmod 600). Contains:
- OBS stream keys (`studio1`, `studio2`)
- `SIGN_API_TOKEN` for backend → `/sign`
- `SRS_API_USER` / `SRS_API_PASS` — pass to SRS box below

### 2. SRS origin

```bash
scp setup-streaming-infra.sh root@<srs-ip>:/root/
ssh root@<srs-ip>
SRS_API_USER=admin \
SRS_API_PASS=<from-STREAM_KEYS.txt> \
bash setup-streaming-infra.sh srs
```

### 3. BunnyCDN

1. Create pull zone → origin: `https://<your-domain>`
2. Enable **Token Authentication**, copy the security key.
3. On haproxy box, edit `/opt/streaming-auth/.env`:
   ```
   BUNNY_TOKEN_KEY=<bunny security key>
   BUNNY_CDN_URL=https://<pullzone>.b-cdn.net
   ```
4. `systemctl restart streaming-auth`

Until step 3, `/sign` returns **503 cdn_not_configured** (fail-closed).

---

## Publish & Play

**OBS:**
- Server: `rtmps://<domain>:1936/live`
- Stream key: `studio1?key=<secret>`

**Viewer (via backend):**
```bash
curl -X POST https://<domain>/sign \
  -H "Authorization: Bearer <SIGN_API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"stream":"studio1","expires_in":600}'
# → { "url": "https://<pullzone>.b-cdn.net/live/studio1.m3u8?token=...&expires=...", ... }
```

Feed that URL to hls.js / native `<video>`.

**Test player:** open `test.html` locally, set sign endpoint + stream name, hit Load. Three latency presets (2–4s / 5–8s / 10–15s target).

---

## Local development (streaming-auth)

```bash
cd streaming-auth
npm install
cp .env.example .env             # fill SIGN_API_TOKEN + STREAM_KEYS + BUNNY_*
npm run start:dev                # hot reload
npm test                         # unit tests
npm run test:e2e                 # e2e covering all 4 routes
npm run build && node dist/main.js
```

### Config layering

Config comes from three sources, applied in order (later wins):

1. **`config/default.yaml`** — non-secret defaults (checked in).
2. **`config/<NODE_ENV>.yaml`** — optional per-env overrides (e.g. `config/production.yaml`).
3. **`.env` / process env** — secrets + any override.

The merged object is validated by a zod schema at boot (`src/config/config.schema.ts`). **Boot fails** with an itemized error if any field is missing/invalid — no silent misconfig.

Env knobs that override YAML:

| Env var | YAML path |
|---------|-----------|
| `PORT` / `BIND_IP` / `TRUST_PROXY` / `BODY_LIMIT` | `server.*` |
| `CORS_ORIGINS` / `CORS_METHODS` / `CORS_HEADERS` | `cors.*` |
| `SIGN_MIN_EXPIRES` / `SIGN_MAX_EXPIRES` / `SIGN_DEFAULT_EXPIRES` | `sign.*` |
| `SIGN_RATE_TTL` / `SIGN_RATE_LIMIT` | `sign.rateLimit.*` |
| `STREAMS_NAME_REGEX` | `streams.nameRegex` |
| `ORIGIN_HOST` / `ORIGIN_PORT` | `origin.*` |
| `LOG_LEVEL` / `LOG_FORMAT` | `logger.*` |
| `BUNNY_CDN_URL` | `bunny.cdnUrl` |

**Env-only (secrets — never in YAML):**
- `SIGN_API_TOKEN` — required, ≥16 chars.
- `STREAM_KEYS` — required, format `name1:secret1,name2:secret2`.
- `BUNNY_TOKEN_KEY` — required for `/sign` to succeed (else 503).

### Extending the service

- **Add an endpoint**: new module under `src/modules/` → import in `app.module.ts`.
- **Back stream keys with a DB**: implement `StreamKeysRepository` (e.g. `PgStreamKeysRepository`), swap the provider in `streams.module.ts`. Zero controller/service changes.
- **Validation**: write zod schemas in `dto/`, apply via `ZodValidationPipe`.
- **Auth another route**: `@UseGuards(ApiTokenGuard)` on the controller/handler.

---

## Security hardening (applied by script)

- TLS 1.2+ only, HSTS, modern cipher suite
- Non-root service users (`streaming-auth`, `srs`)
- Systemd sandboxing: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, namespace restriction (`MemoryDenyWriteExecute` omitted — incompatible with V8 JIT)
- Bearer token on `/sign`; constant-time compare; per-IP rate limit (120/min app + 60/10s HAProxy)
- Config validated by zod on boot — service fails to start on bad/missing config
- Stream name allowlist: `^[a-zA-Z0-9_-]{1,64}$` (enforced in SRS hooks and `/sign` DTO)
- Pino structured JSON logs with auth/cookie headers redacted
- SRS HTTP API behind basic auth; bound to VPC IP (not public)
- SRS pinned to `v6.0-r0` (not `develop`)
- UFW additive (never `--force reset`); SRS ports only accept traffic from HAProxy VPC IP
- Log rotation via journald + logrotate for SRS file log
- Certbot deploy hook rebuilds combined PEM + reloads HAProxy on renewal

---

## Endpoints

**Public (HAProxy):**
- `GET  /health` → `ok`
- `POST /sign` → signed CDN URL _(requires `Authorization: Bearer`)_
- `:1936` RTMPS ingest, `:1935` RTMP (fallback)
- `:443 /live/*.m3u8` CDN origin

**Internal (VPC only):**
- HAProxy `:3000` — `/srs/publish`, `/srs/unpublish`, `/health`
- SRS `:1935` RTMP, `:8080` HTTP/HLS, `:1985` API (basic auth)
- HAProxy stats on `127.0.0.1:8404`

---

## Operations

```bash
# Health
curl -sf https://<domain>/health
curl -sf -u admin:<pass> http://<srs-vpc>:1985/api/v1/versions

# Logs
journalctl -u streaming-auth -f
journalctl -u haproxy -f
journalctl -u srs -f
tail -f /var/log/srs/srs.log

# Restart
systemctl restart streaming-auth haproxy    # on edge
systemctl restart srs                       # on origin

# Re-run setup (idempotent; keeps existing .env)
bash setup-streaming-infra.sh haproxy
```

Rotate `SIGN_API_TOKEN` or stream keys: edit `/opt/streaming-auth/.env` → `systemctl restart streaming-auth`.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `/sign` returns 503 | `BUNNY_TOKEN_KEY` / `BUNNY_CDN_URL` unset in `.env` |
| `/sign` returns 401 | Missing/wrong `Authorization: Bearer` header |
| OBS "Failed to connect" | Domain A record, firewall `:1936`, cert validity |
| Viewer 403 from CDN | Token Auth key mismatch, clock drift, expired URL |
| SRS publish rejected | Stream key mismatch → `journalctl -u streaming-auth` shows `[DENY]` |
| HLS 404 at edge | SRS not generating segments → check on_publish hook reached auth service |

---

## Dev mode (no TLS, not for prod)

```bash
ALLOW_NO_TLS=1 bash setup-streaming-infra.sh haproxy
```

Skips Let's Encrypt, binds plain HTTP on `:80` and RTMP on `:1935`. BunnyCDN + `/sign` still work over HTTP.
