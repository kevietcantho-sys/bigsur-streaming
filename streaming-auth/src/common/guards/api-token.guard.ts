import {
  CanActivate,
  ExecutionContext,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import type { Request } from 'express';
import { TenantsService } from '../../modules/tenants/tenants.service';

/**
 * Bearer token guard with tenant binding.
 *
 * Each tenant has its own SIGN_API_TOKEN_<TENANT> bearer in env. A valid
 * bearer attaches `req.tenant = "<lowercase-id>"`; downstream handlers use
 * that to scope studio names, push keys, etc.
 */
@Injectable()
export class ApiTokenGuard implements CanActivate {
  constructor(private readonly tenants: TenantsService) {}

  canActivate(ctx: ExecutionContext): boolean {
    const req = ctx.switchToHttp().getRequest<Request & { tenant?: string }>();
    const header = req.headers['authorization'] ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    const tenant = token ? this.tenants.matchBearer(token) : null;
    if (!tenant) {
      throw new UnauthorizedException({ error: 'unauthorized' });
    }
    req.tenant = tenant;
    return true;
  }
}
