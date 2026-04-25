import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { safeEqual } from '../../common/crypto.util';

const TENANT_ID_RE = /^[a-z0-9]{2,16}$/;
const BEARER_ENV_RE = /^SIGN_API_TOKEN_([A-Z0-9]{2,16})$/;
const PUSHKEY_ENV_RE = /^PUBLISH_SIGN_KEY_([A-Z0-9]{2,16})$/;

const MIN_BEARER_LEN = 16;
const MIN_PUSH_KEY_LEN = 8;

interface TenantRecord {
  id: string;       // lowercase tenant id, used in URLs / stream names
  bearer: string;   // SIGN_API_TOKEN_<UC>
  pushKey: string;  // PUBLISH_SIGN_KEY_<UC>
}

/**
 * Boot-time tenant registry built from env vars:
 *
 *   SIGN_API_TOKEN_<TENANT>   — bearer for POST /sign/publish
 *   PUBLISH_SIGN_KEY_<TENANT> — md5 input for txSecret signing
 *
 * <TENANT> is uppercase of the tenant id; the tenant id itself appears
 * lowercase in stream names (`<tenant>__<studio>`) and URLs.
 *
 * A tenant must have BOTH env vars set; mismatched pairs fail boot.
 */
@Injectable()
export class TenantsService implements OnModuleInit {
  private readonly logger = new Logger(TenantsService.name);
  private readonly tenants = new Map<string, TenantRecord>();

  onModuleInit(): void {
    const bearers = new Map<string, string>();   // tenant → bearer
    const pushKeys = new Map<string, string>();  // tenant → pushKey

    for (const [k, v] of Object.entries(process.env)) {
      if (!v) continue;
      const bm = k.match(BEARER_ENV_RE);
      if (bm) {
        bearers.set(bm[1].toLowerCase(), v);
        continue;
      }
      const pm = k.match(PUSHKEY_ENV_RE);
      if (pm) {
        pushKeys.set(pm[1].toLowerCase(), v);
      }
    }

    const ids = new Set([...bearers.keys(), ...pushKeys.keys()]);
    const errors: string[] = [];

    for (const id of ids) {
      if (!TENANT_ID_RE.test(id)) {
        errors.push(`tenant id "${id}" must match ${TENANT_ID_RE}`);
        continue;
      }
      const bearer = bearers.get(id);
      const pushKey = pushKeys.get(id);
      if (!bearer) {
        errors.push(`tenant ${id}: missing SIGN_API_TOKEN_${id.toUpperCase()}`);
        continue;
      }
      if (!pushKey) {
        errors.push(`tenant ${id}: missing PUBLISH_SIGN_KEY_${id.toUpperCase()}`);
        continue;
      }
      if (bearer.length < MIN_BEARER_LEN) {
        errors.push(`tenant ${id}: SIGN_API_TOKEN must be ≥${MIN_BEARER_LEN} chars`);
        continue;
      }
      if (pushKey.length < MIN_PUSH_KEY_LEN) {
        errors.push(`tenant ${id}: PUBLISH_SIGN_KEY must be ≥${MIN_PUSH_KEY_LEN} chars`);
        continue;
      }
      this.tenants.set(id, { id, bearer, pushKey });
    }

    // Reject duplicate bearers — would let one tenant's token authorize another.
    const seen = new Map<string, string>();
    for (const t of this.tenants.values()) {
      const prev = seen.get(t.bearer);
      if (prev) errors.push(`tenants ${prev} and ${t.id} share the same bearer`);
      else seen.set(t.bearer, t.id);
    }

    if (errors.length) {
      throw new Error(`Tenant config invalid:\n  • ${errors.join('\n  • ')}`);
    }

    this.logger.log(
      `Loaded ${this.tenants.size} tenant(s): ${[...this.tenants.keys()].join(', ') || '(none)'}`,
    );
  }

  /** Resolve bearer → tenant id. Constant-time across all configured tenants. */
  matchBearer(bearer: string): string | null {
    let match: string | null = null;
    for (const t of this.tenants.values()) {
      // safeEqual is constant-time per pair; iterate every tenant so total
      // time depends on tenant count, not on which tenant matched.
      if (safeEqual(bearer, t.bearer)) match = t.id;
    }
    return match;
  }

  pushKey(tenant: string): string | null {
    return this.tenants.get(tenant)?.pushKey ?? null;
  }

  has(tenant: string): boolean {
    return this.tenants.has(tenant);
  }

  count(): number {
    return this.tenants.size;
  }

  /** Split `<tenant>__<studio>` from a stream name. */
  static parseStream(stream: string): { tenant: string; studio: string } | null {
    const idx = stream.indexOf('__');
    if (idx <= 0 || idx >= stream.length - 2) return null;
    return { tenant: stream.slice(0, idx), studio: stream.slice(idx + 2) };
  }
}
