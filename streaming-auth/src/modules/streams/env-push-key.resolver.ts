import { Injectable } from '@nestjs/common';
import { AppConfigService } from '../../config/app-config.service';
import { PushKeyResolver } from './push-key.resolver';

/**
 * Single-key impl: every stream uses PUBLISH_SIGN_KEY from env.
 * Returns null when the key is empty so callers fail closed.
 */
@Injectable()
export class EnvPushKeyResolver extends PushKeyResolver {
  constructor(private readonly config: AppConfigService) { super(); }

  async resolve(_stream: string): Promise<string | null> {
    return this.config.publish.signKey || null;
  }
}
