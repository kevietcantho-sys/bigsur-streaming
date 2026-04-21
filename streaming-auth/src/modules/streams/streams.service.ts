import { Injectable, Logger } from '@nestjs/common';
import { AppConfigService } from '../../config/app-config.service';
import { safeEqual } from '../../common/crypto.util';
import { StreamKeysRepository } from './stream-keys.repository';

export interface PublishCheckResult {
  allowed: boolean;
  reason?: string;
}

@Injectable()
export class StreamsService {
  private readonly logger = new Logger(StreamsService.name);
  private readonly nameRe: RegExp;

  constructor(
    private readonly config: AppConfigService,
    private readonly repo: StreamKeysRepository,
  ) {
    this.nameRe = new RegExp(this.config.streams.nameRegex);
  }

  validName(name: unknown): name is string {
    return typeof name === 'string' && this.nameRe.test(name);
  }

  /** Extract `key` query param from SRS-supplied `param` string: `?key=xxx&...` */
  extractKey(param: string | undefined): string {
    if (!param) return '';
    const q = param.startsWith('?') ? param.slice(1) : param;
    return new URLSearchParams(q).get('key') ?? '';
  }

  async checkPublish(stream: unknown, param: unknown): Promise<PublishCheckResult> {
    if (!this.validName(stream)) {
      this.logger.warn(`DENY publish: invalid stream name ${JSON.stringify(stream)}`);
      return { allowed: false, reason: 'invalid stream' };
    }
    const providedKey = this.extractKey(typeof param === 'string' ? param : '');
    const expectedKey = await this.repo.findSecret(stream);
    if (!expectedKey || !safeEqual(providedKey, expectedKey)) {
      this.logger.warn(`DENY publish ${stream}`);
      return { allowed: false, reason: 'bad key' };
    }
    this.logger.log(`ALLOW publish ${stream}`);
    return { allowed: true };
  }
}
