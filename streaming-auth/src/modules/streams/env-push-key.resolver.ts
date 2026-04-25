import { Injectable } from '@nestjs/common';
import { PushKeyResolver } from './push-key.resolver';
import { TenantsService } from '../tenants/tenants.service';

/**
 * Tenant-scoped resolver: stream `<tenant>__<studio>` → tenant's push key.
 * Returns null when the stream isn't tenant-prefixed or the tenant is
 * unknown so callers fail closed (deny publish, refuse to sign).
 */
@Injectable()
export class EnvPushKeyResolver extends PushKeyResolver {
  constructor(private readonly tenants: TenantsService) { super(); }

  async resolve(stream: string): Promise<string | null> {
    const parsed = TenantsService.parseStream(stream);
    if (!parsed) return null;
    return this.tenants.pushKey(parsed.tenant);
  }
}
