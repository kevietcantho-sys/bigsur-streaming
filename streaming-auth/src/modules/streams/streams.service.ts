import { Injectable, Logger } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { AppConfigService } from '../../config/app-config.service';
import { safeEqual } from '../../common/crypto.util';
import { PushKeyResolver } from './push-key.resolver';

export interface PublishCheckResult {
  allowed: boolean;
  reason?: string;
}

/**
 * Extracted publish-URL signature. `param` arrives as a raw SRS query
 * string (`?txSecret=<md5>&txTime=<hex>`). Missing/malformed values
 * yield empty strings so the caller can fail closed without throwing.
 */
interface PublishSig {
  txSecret: string;
  txTime: string;
}

@Injectable()
export class StreamsService {
  private readonly logger = new Logger(StreamsService.name);
  private readonly nameRe: RegExp;

  constructor(
    private readonly config: AppConfigService,
    private readonly pushKeys: PushKeyResolver,
  ) {
    this.nameRe = new RegExp(this.config.streams.nameRegex);
  }

  validName(name: unknown): name is string {
    return typeof name === 'string' && this.nameRe.test(name);
  }

  /**
   * Pull txSecret + txTime out of the query string SRS forwards from OBS.
   * Accepts both leading-`?` and bare forms to match SRS hook variants.
   */
  extractSig(param: string | undefined): PublishSig {
    if (!param) return { txSecret: '', txTime: '' };
    const q = param.startsWith('?') ? param.slice(1) : param;
    const usp = new URLSearchParams(q);
    return {
      txSecret: usp.get('txSecret') ?? '',
      txTime: usp.get('txTime') ?? '',
    };
  }

  async checkPublish(stream: unknown, param: unknown): Promise<PublishCheckResult> {
    if (!this.validName(stream)) {
      this.logger.warn(`DENY publish: invalid stream name ${JSON.stringify(stream)}`);
      return { allowed: false, reason: 'invalid stream' };
    }

    const { txSecret, txTime } = this.extractSig(
      typeof param === 'string' ? param : '',
    );
    if (!txSecret || !txTime) {
      this.logger.warn(`DENY publish ${stream}: missing txSecret/txTime`);
      return { allowed: false, reason: 'missing signature' };
    }

    const expiresAt = parseInt(txTime, 16);
    if (!Number.isFinite(expiresAt) || expiresAt <= 0) {
      this.logger.warn(`DENY publish ${stream}: invalid txTime`);
      return { allowed: false, reason: 'invalid txTime' };
    }
    if (expiresAt < Math.floor(Date.now() / 1000)) {
      this.logger.warn(`DENY publish ${stream}: expired at ${expiresAt}`);
      return { allowed: false, reason: 'expired' };
    }

    const signKey = await this.pushKeys.resolve(stream);
    if (!signKey) {
      this.logger.warn(`DENY publish ${stream}: no push key configured`);
      return { allowed: false, reason: 'no key' };
    }

    const expected = createHash('md5')
      .update(signKey + stream + txTime)
      .digest('hex');
    if (!safeEqual(txSecret.toLowerCase(), expected)) {
      this.logger.warn(`DENY publish ${stream}: bad signature`);
      return { allowed: false, reason: 'bad signature' };
    }

    this.logger.log(`ALLOW publish ${stream}`);
    return { allowed: true };
  }
}
