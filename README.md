# bigsur-streaming

Production-hardened live streaming infrastructure: **OBS → HAProxy (TLS edge) → SRS (LL-HLS origin) → BunnyCDN → Viewer**.

Two-server bootstrap via a single shell script, plus a browser test player with adaptive latency modes.

---

## Architecture

```
   OBS ──── RTMP:1935 ──────────────▶ ┌──────────────────────────┐
   (bspush.* grey-cloud, direct)      │ haproxy-edge             │ ─ RTMP:1935 ──▶ SRS (VPC)
                                      │ • TLS termination        │
   BunnyCDN ─ HTTPS:443 pull ───────▶ │ • Cloudflare Origin Cert │ ─ HTTP:8080 ──▶ SRS /live/*.m3u8
   (origin.* grey-cloud, direct)      │ • streaming-auth (Node)  │
                                      │ • Per-IP rate limiting   │
   Backend ─ HTTPS:443 /sign/publish ▶│                          │
   (api.* orange-cloud via CF)        └──────────────────────────┘
                                                                     ┌──────────────────┐
                                                                     │ srs-origin       │
   Viewer ── HTTPS:443 ─▶ BunnyCDN edge ─▶ HAProxy/origin             │ • LL-HLS (2s)    │
   (bigsur-hls.b-cdn.net, client-signed URL)                          │ • HTTP-FLV       │
                                                                     │ • publish hooks  │
                                                                     └──────────────────┘
```

- **Ingest**: RTMPS on `:1936` (Let's Encrypt cert when `LETSENCRYPT_EMAIL` is set) or plain RTMP on `:1935` otherwise. Cloudflare cannot proxy RTMP/RTMPS, so ingest DNS must be grey-cloud regardless. HAProxy terminates TLS and forwards plain RTMP to SRS `:1935` over the VPC.
- **Playback origin pull**: BunnyCDN pulls LL-HLS from `https://origin.example.com` (grey-cloud) on `:443` → SRS `:8080` over VPC. BunnyCDN must have **"Verify origin SSL certificate" off** because the Cloudflare Origin Cert is not publicly trusted.
- **Publish sign API**: Backend calls `https://api.example.com/sign/publish` (orange-cloud) — Cloudflare terminates public TLS with its Universal SSL cert, then re-encrypts to HAProxy using the Cloudflare Origin Cert.
- **Viewer playback**: BunnyCDN edge serves the HLS manifest + segments to viewers via a **client-signed** URL — each client holds its own `(pull_zone, BUNNY_TOKEN_KEY)` pair and computes the BunnyCDN token locally. No server round-trip per playback session.
- **Auth**:
  - Publishers: backend calls `POST /sign/publish` (Bearer) → returns `rtmp://.../<studio>?txSecret=<md5>&txTime=<hex>` (and `rtmps://...` when `PUBLISH_RTMPS_ENABLED=true`). SRS `on_publish` hits `streaming-auth /srs/publish` which recomputes `md5(PUBLISH_SIGN_KEY + studio + txTime)` and rejects expired / mismatched signatures.
  - Viewers: client mints the BunnyCDN signed URL directly using its per-tenant token key. The legacy `POST /sign` endpoint has been removed; reference implementation kept at `streaming-auth/src/modules/sign/bunny.service.ts` for clients to port.

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
├── config/default.yaml          # non-secret defaults (ports, limits, regex, publish app)
├── src/
│   ├── main.ts                  # bootstrap (trust proxy, CORS, shutdown hooks)
│   ├── app.module.ts            # wires config + logger + throttler + modules
│   ├── config/                  # YAML loader + zod schema + typed service
│   ├── common/                  # ApiTokenGuard, ZodValidationPipe, filters
│   └── modules/
│       ├── health/              # GET  /health
│       ├── streams/             # POST /srs/publish, /srs/unpublish (VPC-only)
│       │   ├── push-key.resolver.ts           # publish-key indirection (per-client ready)
│       │   └── env-push-key.resolver.ts       # single PUBLISH_SIGN_KEY impl
│       └── sign/                # POST /sign/publish (Bearer guard + rate limited)
│           ├── bigsur-publish.service.ts   # txSecret/txTime publish URL minter (wired)
│           ├── bunny.service.ts            # md5 token minting — REFERENCE ONLY (clients sign locally)
│           ├── sign.service.ts             # legacy playback signer — REFERENCE ONLY (unwired)
│           └── dto/                        # zod request schemas
└── test/app.e2e-spec.ts         # supertest coverage for all 5 routes
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
| `PUBLISH_HOST` | _(required)_ — OBS ingest hostname, grey-cloud DNS (e.g. `bspush.example.com`) |
| `PLAYBACK_ORIGIN_HOST` | _(required)_ — BunnyCDN origin hostname, grey-cloud DNS (e.g. `origin.example.com`) |
| `SSL_CERT_PATH` | `/etc/ssl/cloudflare/origin.pem` — Cloudflare Origin Certificate (for :443) |
| `SSL_KEY_PATH` | `/etc/ssl/cloudflare/origin.key` — Cloudflare Origin Certificate key |
| `LETSENCRYPT_EMAIL` | _(optional)_ — if set, script issues a Let's Encrypt cert for `$PUBLISH_HOST` and uses it on :1936 so OBS can publish via RTMPS. Requires public port 80 for HTTP-01 challenge. |
| `ALLOW_NO_TLS` | `0` — set `1` for dev only |

> Cloudflare does not proxy RTMP/RTMPS (ports 1935/1936). The `PUBLISH_HOST` DNS record **must be grey-cloud** (DNS only). `PLAYBACK_ORIGIN_HOST` should also be grey-cloud so BunnyCDN pulls directly from origin without stacking two CDNs. Use a wildcard Cloudflare Origin Certificate (e.g. `*.example.com`) to cover both hostnames.

---

## Deploy

The setup script expects the **whole repo** on the HAProxy box so it can rsync + build `streaming-auth/` in place.

### 1. HAProxy edge

```bash
# Sync repo to the box (excludes local builds/secrets)
rsync -a --exclude node_modules --exclude dist --exclude .env \
  ./ root@<haproxy-ip>:/root/bigsur-streaming/

ssh root@<haproxy-ip>

# Upload the Cloudflare Origin Certificate + key first
# (generated in CF dashboard → SSL/TLS → Origin Server → Create Certificate,
#  using a wildcard like *.example.com so it covers both hostnames)
sudo mkdir -p /etc/ssl/cloudflare
sudo tee /etc/ssl/cloudflare/origin.pem > /dev/null   # paste cert, Enter, Ctrl+D
sudo tee /etc/ssl/cloudflare/origin.key > /dev/null   # paste key,  Enter, Ctrl+D
sudo chmod 644 /etc/ssl/cloudflare/origin.pem
sudo chmod 600 /etc/ssl/cloudflare/origin.key

cd /root/bigsur-streaming
PUBLISH_HOST=bspush.example.com \
PLAYBACK_ORIGIN_HOST=origin.example.com \
LETSENCRYPT_EMAIL=ops@example.com \
bash setup-streaming-infra.sh haproxy
```

The script will:
1. Install Node 20, HAProxy, certbot, rsync.
2. Build `/etc/haproxy/certs/origin.pem` from `$SSL_CERT_PATH` + `$SSL_KEY_PATH` (CF Origin Cert, bound on `:443`).
3. If `$LETSENCRYPT_EMAIL` is set: issue a Let's Encrypt cert for `$PUBLISH_HOST` via HTTP-01 on port 80, build `/etc/haproxy/certs/publish.pem`, bind it on `:1936` (RTMPS), and install pre/post/deploy renewal hooks (HAProxy briefly stops for the challenge during renewal).
4. Copy `streaming-auth/` → `/opt/streaming-auth/`, run `npm ci && npm run build && npm prune --omit=dev`.
5. Generate `/opt/streaming-auth/.env` with random `SIGN_API_TOKEN`, `PUBLISH_SIGN_KEY`, SRS API creds. `PUBLISH_DOMAIN` defaults to `$PUBLISH_HOST`, `PUBLISH_APP=luckylive`.
6. Install the `streaming-auth.service` systemd unit (running `node dist/main.js`).
7. Write HAProxy config with TLS, rate limits, CORS, and `/sign/publish` + SRS backend routing.

> **RTMPS vs RTMP**: OBS validates the cert chain against public CAs on RTMPS. The Cloudflare Origin Certificate is not publicly trusted, so using it on :1936 breaks OBS. The script solves this with Let's Encrypt (set `LETSENCRYPT_EMAIL`). If you skip LE, :1936 falls back to the CF Origin Cert and OBS will reject it — use plain RTMP on :1935 in that case.

Generates credentials at `/root/STREAM_KEYS.txt` (chmod 600). Contains:
- `SIGN_API_TOKEN` for backend → `/sign/publish`
- `PUBLISH_SIGN_KEY` (md5 input for publish URL signing — keep private)
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

**Pull zone basics**
1. Create pull zone → origin URL: `https://<PLAYBACK_ORIGIN_HOST>`.
2. Pull Zone → **Origin** → turn **"Verify origin SSL certificate" off** (the Cloudflare Origin Cert is issued by Cloudflare's private CA and not publicly trusted; traffic remains TLS-encrypted regardless).

**Caching** — let origin Cache-Control headers drive freshness (HAProxy sets them automatically since commit `feat: HAProxy Cache-Control headers`):
3. Pull Zone → **Caching** → enable **"Respect origin cache control"**.
4. Keep one safety-net Edge Rule: `Status Code = 404, 502, 503, 504` → Override Cache Time = `1 second` (prevents poisoned negative caches during origin hiccups).
5. (Optional) Pull Zone → **Caching** → enable compression (Brotli + gzip) — manifests are text, small win on mobile.

**Token Authentication** — signed URLs, required for end-to-end playback:
6. Pull Zone → **Security** → **Token Authentication** → enable.
7. Copy the **Authentication Key** (shown once). Hand this + the pull zone hostname to the client owner — they sign URLs locally.
8. **Don't enable "Token IP Validation"** at the zone level — let the client decide per-request via the `viewer_ip` field. Zone-wide IP pinning breaks NAT'd mobile viewers.
9. No need to touch "Allowed Referrers" unless you also want hotlink protection on top of tokens.

**Per-client model** — give each tenant its own pull zone + token key so a leak only blasts one tenant. The auth service no longer needs `BUNNY_*` secrets — playback signing is fully client-side.

**How the signer works** (reference for client implementations, `streaming-auth/src/modules/sign/bunny.service.ts`):
- Signs with path-prefix mode: `md5(BUNNY_TOKEN_KEY + "/live/" + expires [+ viewer_ip])`
- Includes `token_path=/live/` in the URL — same token validates for the `.m3u8` manifest *and* every `.ts` / `.m4s` segment under `/live/`
- Adds `&expires=<unix_ts>` — absolute timestamp (not TTL)
- Optional `viewer_ip` pins the token to a single client IP

**Recommended client posture**:
- Short token TTL (1–6h) so a stolen URL expires fast even if the key behind it is intact.
- Mint per-session — never embed long-lived signed URLs in HTML/CDN-cacheable payloads.
- Treat `BUNNY_TOKEN_KEY` as a backend secret. **Do not** ship it inside browser/mobile bundles — sign on the client's own server tier and hand the URL to the player.

**Verify end-to-end after setup** (with a token your client minted):
```bash
# Unsigned request — must 403
curl -s -o /dev/null -w '%{http_code}\n' \
  https://<pullzone>.b-cdn.net/live/studio1.m3u8
# → 403

# Signed URL (minted by the client using its BUNNY_TOKEN_KEY) — must play
curl -I 'https://<pullzone>.b-cdn.net/live/studio1.m3u8?token=<...>&expires=<...>'
# → HTTP/2 200  (content-type: application/vnd.apple.mpegurl)
```

### 4. Backend → `/sign/publish` API (optional: via Cloudflare)

The `/sign/publish` endpoint works on any hostname that resolves to the HAProxy edge. Easiest for backend callers: add an **orange-cloud** DNS record so Cloudflare serves a publicly-trusted cert:

| Record | Cloud | Points to | Role |
|---|---|---|---|
| `api.example.com` | 🟠 proxied | `HAPROXY_PUBLIC_IP` | Backend → `POST /sign/publish` (public TLS via CF Universal SSL) |

Backend calls `https://api.example.com/sign/publish` — no cert pinning needed, standard public CA chain.

---

## Publish & Play

**OBS (RTMPS if `LETSENCRYPT_EMAIL` was set, else plain RTMP):**

Backend mints a signed URL per publish session via `POST /sign/publish`:

```bash
curl -X POST https://api.example.com/sign/publish \
  -H "Authorization: Bearer <SIGN_API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"studio":"LR-MNC3HOF8-5A9F04","expires_in":2592000}'
# → {
#     "url":       "rtmp://bspush.example.com/luckylive/LR-MNC3HOF8-5A9F04?txSecret=<md5>&txTime=<hex>",
#     "url_rtmps": "rtmps://bspush.example.com:1936/luckylive/LR-MNC3HOF8-5A9F04?txSecret=<md5>&txTime=<hex>",
#     "stream": "...", "txTime": "...", "txSecret": "...", "expires": ..., "expires_at": "..."
#   }
```

`url_rtmps` is only present when `PUBLISH_RTMPS_ENABLED=true` (set by `setup-streaming-infra.sh` automatically when `LETSENCRYPT_EMAIL` was provided). Without an LE cert on `:1936`, OBS rejects the handshake — keep the flag off and stick to plain RTMP.

Split the returned URL at the last `/` in OBS:
- **Server**: `rtmp://$PUBLISH_HOST/luckylive` (or `rtmps://$PUBLISH_HOST:1936/luckylive`)
- **Stream key**: `<studio>?txSecret=<md5>&txTime=<hex>`

SRS's `on_publish` hook recomputes `md5(PUBLISH_SIGN_KEY + studio + txTime)` via
`streaming-auth/src/modules/streams/streams.service.ts` and rejects expired /
mismatched signatures. Today a single `PUBLISH_SIGN_KEY` signs all studios;
`PushKeyResolver` (`streaming-auth/src/modules/streams/push-key.resolver.ts`)
is the indirection point for future per-client keys.

#### Recommended OBS encoder settings

SRS does not transcode — whatever OBS pushes is exactly what viewers receive.
Pick one tier per studio. Keyframe interval **must** be `2` to match the 2-second
LL-HLS segment boundary; anything else degrades latency and segment alignment.

**Common to every tier**

- **Settings → Stream**
  - Service: `Custom...`
  - Server: `rtmp://$PUBLISH_HOST/luckylive` (or `rtmps://$PUBLISH_HOST:1936/luckylive` with LE)
  - Stream Key: full `<studio>?txSecret=…&txTime=…` returned by `POST /sign/publish`
- **Settings → Output → Mode: Advanced → Streaming**
  - Encoder: `x264` (universal) or `NVENC H.264` / `Apple VT H.264` if available
  - Rate Control: `CBR`
  - Keyframe Interval: `2` (do not leave on "auto")
  - CPU Usage Preset (x264): `veryfast`
  - Profile: `main` (or `baseline` for 360p on weak devices)
  - B-frames: `2` (or `0` on NVENC for lower latency)
- **Settings → Output → Audio**: AAC, 128 kbps (96 kbps acceptable for 360p)
- **Settings → Video**: Downscale Filter `Lanczos`

**Per-tier values**

| Tier | Output (Scaled) Resolution | FPS | Video Bitrate | Audio | Upload budget |
|---|---|---|---|---|---|
| 360p | `640x360` | 30 | 700 kbps | 96 kbps | ~0.8 Mbps |
| 480p | `854x480` | 30 | 1200 kbps | 128 kbps | ~1.4 Mbps |
| 720p | `1280x720` | 30 | 2500 kbps | 128 kbps | ~2.7 Mbps |
| 1080p | `1920x1080` | 30 | 4500 kbps | 128 kbps | ~4.7 Mbps |

> **Verify after Start Streaming**: bottom-right OBS stats — **dropped frames < 1%**. If climbing, drop bitrate by 30% or switch CPU preset to `superfast`. CBR is required for live (VBR causes spikes that break the 2s segment cadence).

For adaptive bitrate (viewer auto-switches quality) without paying for SRS-side
transcoding, run multiple OBS instances (or one OBS with multi-output plugin)
publishing the same content under different studio codes — e.g. `LR-XXX-high`,
`LR-XXX-mid`, `LR-XXX-low` — then assemble a master `.m3u8` referencing the
three rendition manifests.

**Viewer (client-signed):** the client mints the BunnyCDN URL locally with its own `BUNNY_TOKEN_KEY`. Reference algorithm in `streaming-auth/src/modules/sign/bunny.service.ts`. Pseudocode:

```
expires = floor(now/1000) + ttl
hashInput = BUNNY_TOKEN_KEY + "/live/" + expires        # + viewer_ip if pinning
token    = base64url(md5_bytes(hashInput))              # raw md5, not hex
url      = `https://<pullzone>.b-cdn.net/live/<stream>.m3u8?token=${token}&token_path=%2Flive%2F&expires=${expires}`
```

Feed that URL to hls.js / native `<video>`.

---

## Test player (`test.html`)

> **Note**: `test.html` was wired to the now-removed `POST /sign` endpoint. Use it as a UI scaffold only — adapt the sign step to call your client-side signer (or a tenant backend that holds `BUNNY_TOKEN_KEY`) before hitting Load.

Standalone hls.js page with three latency presets (2–4s / 5–8s / 10–15s target), live stats (latency, buffer, bitrate, resolution, dropped frames), and a rolling log.

### Run it locally

`fetch()` is blocked from `file://` in some browsers, so serve it over HTTP:

```bash
# From the repo root on your machine
python3 -m http.server 8000
# → http://localhost:8000/test.html
```

### Prerequisites for it to actually play

- OBS is currently publishing to `rtmp://$PUBLISH_HOST/luckylive` with a `<studio>?txSecret=...&txTime=...` key minted by `POST /sign/publish`.
- BunnyCDN pull zone has Token Authentication enabled and the page can produce a valid signed URL (locally or via a tenant backend).
- BunnyCDN pull zone is configured with origin `https://$PLAYBACK_ORIGIN_HOST` and **"Verify origin SSL certificate"** disabled.

---

## Local development (streaming-auth)

```bash
cd streaming-auth
npm install
cp .env.example .env             # fill SIGN_API_TOKEN + PUBLISH_* + BUNNY_*
npm run start:dev                # hot reload
npm test                         # unit tests
npm run test:e2e                 # e2e covering all 5 routes
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
| `BUNNY_CDN_URL` | `bunny.cdnUrl` _(unused after playback signing moved client-side; kept for reference signer)_ |
| `PUBLISH_DOMAIN` / `PUBLISH_APP` | `publish.pushDomain` / `publish.app` |
| `PUBLISH_RTMPS_ENABLED` / `PUBLISH_RTMPS_PORT` | `publish.rtmpsEnabled` / `publish.rtmpsPort` |

**Env-only (secrets — never in YAML):**
- `SIGN_API_TOKEN` — required, ≥16 chars. Bearer for `/sign/publish`.
- `PUBLISH_SIGN_KEY` — required for `/sign/publish` + `/srs/publish` to succeed (else 503/deny). Signs all studios today; one key per client in the planned per-client model.
- `BUNNY_TOKEN_KEY` — **no longer required server-side**. Now held per-tenant by clients, who sign playback URLs locally. The reference signer (`bunny.service.ts`) still reads it if you want to sanity-check the algorithm during development.

### Extending the service

- **Add an endpoint**: new module under `src/modules/` → import in `app.module.ts`.
- **Per-client push keys**: implement `PushKeyResolver.resolve(stream)` to look up `stream → client → pushKey` (e.g. `ClientPushKeyResolver`) and swap the provider in `streams.module.ts`. Minter (`bigsur-publish.service.ts`) and validator (`streams.service.ts`) both read through the resolver — no other changes needed. A leaked key then only invalidates the studios owned by that client.
- **Validation**: write zod schemas in `dto/`, apply via `ZodValidationPipe`.
- **Auth another route**: `@UseGuards(ApiTokenGuard)` on the controller/handler.

---

## Security hardening (applied by script)

- TLS 1.2+ only, HSTS, modern cipher suite
- Non-root service users (`streaming-auth`, `srs`)
- Systemd sandboxing: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, namespace restriction (`MemoryDenyWriteExecute` omitted — incompatible with V8 JIT)
- Bearer token on `/sign/publish`; constant-time compare; per-IP rate limit (120/min app + 60/10s HAProxy)
- Config validated by zod on boot — service fails to start on bad/missing config
- Stream name allowlist: `^[a-zA-Z0-9_-]{1,64}$` (enforced in SRS hooks and `/sign/publish` DTO)
- Pino structured JSON logs with auth/cookie headers redacted
- SRS HTTP API behind basic auth; bound to VPC IP (not public)
- SRS pinned to `v6.0-r0` (not `develop`)
- UFW additive (never `--force reset`); SRS ports only accept traffic from HAProxy VPC IP
- Log rotation via journald + logrotate for SRS file log
- TLS via Cloudflare Origin Certificate (15-year validity; no ACME renewal loop)

---

## Endpoints

**Public (HAProxy):**
- `GET  /health` → `ok`
- `POST /sign/publish` → signed RTMP push URL for OBS _(requires `Authorization: Bearer`)_
- `:1936` RTMPS ingest, `:1935` RTMP (fallback)
- `:443 /live/*.m3u8` CDN origin

> Playback signing (`POST /sign`) was removed — clients hold their own `BUNNY_TOKEN_KEY` and mint URLs locally. Reference signer kept at `streaming-auth/src/modules/sign/{sign,bunny}.service.ts`.

**Internal (VPC only):**
- HAProxy `:3000` — `/srs/publish`, `/srs/unpublish`, `/health`
- SRS `:1935` RTMP, `:8080` HTTP/HLS, `:1985` API (basic auth)
- HAProxy stats on `127.0.0.1:8404`

---

## Operations

```bash
# Health
curl -sf https://api.example.com/health
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

Rotate `SIGN_API_TOKEN` or `PUBLISH_SIGN_KEY`: edit `/opt/streaming-auth/.env` → `systemctl restart streaming-auth`. Rotating `PUBLISH_SIGN_KEY` invalidates every live OBS URL — publishers must re-fetch from `/sign/publish`.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `/sign/publish` returns 503 | `PUBLISH_DOMAIN` / `PUBLISH_SIGN_KEY` unset in `.env` |
| `/sign/publish` returns 401 | Missing/wrong `Authorization: Bearer` header |
| Viewer 403 from CDN with valid-looking token | Token key on the client doesn't match the BunnyCDN pull zone's Authentication Key, or clock drift on the signer (token `expires` is absolute unix ts) |
| OBS "Failed to connect socket" (25s timeout) | `PUBLISH_HOST` DNS is orange-cloud. CF doesn't proxy 1935/1936 — flip to grey. |
| OBS "invalid SSL certificate" on RTMPS | OBS rejects the Cloudflare Origin Cert (not publicly trusted). Use plain RTMP on `:1935` or issue a Let's Encrypt cert via DNS-01 for `$PUBLISH_HOST`. |
| Viewer 403 from CDN | Token Auth key mismatch, clock drift, expired URL, **or** the URL was fetched unsigned (Token Authentication is on at the pull zone) |
| BunnyCDN origin fetch fails with TLS error | Turn off "Verify origin SSL certificate" in the pull zone |
| SRS systemd exits 255, log says `getifaddrs failed … Address family not supported` | `RestrictAddressFamilies` missing `AF_NETLINK`. Fixed in current script — `daemon-reload` + restart. |
| SRS publish rejected | `journalctl -u streaming-auth` shows the reason: `missing signature`, `expired`, `bad signature`, `no key`, or `invalid stream`. Re-mint via `/sign/publish` (the URL has a finite `txTime`). |
| HLS 404 at edge | SRS not generating segments → check `on_publish` hook reached auth service, and OBS is actively publishing |

---

## Dev mode (no TLS, not for prod)

```bash
ALLOW_NO_TLS=1 bash setup-streaming-infra.sh haproxy
```

Skips the Cloudflare Origin Cert lookup and binds plain HTTP on `:80` + RTMP on `:1935`. BunnyCDN + `/sign/publish` still work over HTTP.

---

## Production notes — 2026-04-25

Captured from the first production rollout. Update this section as the deployment evolves.

### Stack in use

- **Origin**: Vultr SG, High-Frequency 1-2 vCPU, SRS, LL-HLS.
- **CDN**: Bunny Volume Network, edge SG.
- **Player**: Video.js + VHS, custom token-refresh hook (`useStreamPlayer.ts` on the client side).

### Config decisions

- **Origin Shield: OFF** — Bunny's shield POPs are Paris/Chicago, both far from SG. Shielding via a distant POP would add a transcontinental hop and hurt p50 latency more than it helps offload.
- **Request Coalescing: ON** — replaces shield for thundering-herd protection. A single origin fetch fans out to all concurrent viewers waiting on the same segment.
- **Edge rule**: don't cache `404 / 502 / 503 / 504`, override cache time to `1s`. Prevents poisoned negative caches when the origin hiccups during a publish gap.

### Known issues to monitor

1. **Token refresh fails silently when the backend times out** — partial patch landed in `useStreamPlayer.ts` (see chat 2026-04-25). Permanent fix gated on observed CDN 403 rate; trip threshold is **>5%**.
2. **Hit rate at 57% with 2 viewers** — math is correct given the warmup pattern (cold segments + short test session). Expectation is **>95% at 100+ concurrent viewers**. If hit rate stays low at scale, first thing to check is whether the cache key includes the BunnyCDN token (it must not — token is a query param that should be stripped from the cache key, otherwise every viewer's URL is unique and uncacheable).
3. **Player retry loop on expired token** — when a token expires mid-session, VHS retries indefinitely. Current workaround is "user closes the tab and reopens." Permanent fix deferred until production data clarifies whether the loop is the player retry policy or a token-refresh edge case in the hook.
