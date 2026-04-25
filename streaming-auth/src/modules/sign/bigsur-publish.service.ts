import { Injectable, ServiceUnavailableException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { AppConfigService } from '../../config/app-config.service';
import { PushKeyResolver } from '../streams/push-key.resolver';

export interface SignedPublishUrl {
  url: string;             // rtmp://… (always present)
  url_rtmps?: string;      // rtmps://…:<port>/… (only when PUBLISH_RTMPS_ENABLED=true)
  stream: string;          // <tenant>__<studio>
  txTime: string;          // lowercase hex of unix-seconds expiry
  txSecret: string;        // md5(signKey + stream + txTime)
  expires: number;         // unix seconds
  expires_at: string;      // iso8601
}

/**
 * Mint a signed RTMP push URL (txSecret/txTime scheme).
 *
 * Format: rtmp://<pushDomain>/<app>/<tenant>__<studio>?txSecret=<md5>&txTime=<hex>
 * Scheme: txSecret = md5(signKey + stream + txTime), txTime = hex(unix_expires).
 *
 * `tenant` is bound by the guard from the bearer token — callers cannot
 * pass it directly. PushKeyResolver looks up the tenant's PUBLISH_SIGN_KEY
 * via TenantsService; SRS's on_publish hook reuses the same resolver.
 */
@Injectable()
export class BigsurPublishService {
  constructor(
    private readonly config: AppConfigService,
    private readonly pushKeys: PushKeyResolver,
  ) {}

  async sign(tenant: string, studio: string, expiresIn: number): Promise<SignedPublishUrl> {
    if (!this.config.publish.pushDomain) {
      throw new ServiceUnavailableException({
        error: 'publish_not_configured',
        hint: 'Set PUBLISH_DOMAIN',
      });
    }

    const stream = `${tenant}__${studio}`;
    const signKey = await this.pushKeys.resolve(stream);
    if (!signKey) {
      throw new ServiceUnavailableException({
        error: 'publish_not_configured',
        hint: `No push key configured for tenant ${tenant}`,
      });
    }

    const {
      pushDomain, app, minExpires, maxExpires, defaultExpires,
      rtmpsEnabled, rtmpsPort,
    } = this.config.publish;

    const ttl = Math.max(
      minExpires,
      Math.min(maxExpires, expiresIn || defaultExpires),
    );
    const expires = Math.floor(Date.now() / 1000) + ttl;
    const txTime = expires.toString(16);

    const txSecret = createHash('md5')
      .update(signKey + stream + txTime)
      .digest('hex');

    const query = `?txSecret=${txSecret}&txTime=${txTime}`;
    const url = `rtmp://${pushDomain}/${app}/${stream}${query}`;
    const url_rtmps = rtmpsEnabled
      ? `rtmps://${pushDomain}:${rtmpsPort}/${app}/${stream}${query}`
      : undefined;

    return {
      url,
      ...(url_rtmps ? { url_rtmps } : {}),
      stream,
      txTime,
      txSecret,
      expires,
      expires_at: new Date(expires * 1000).toISOString(),
    };
  }
}
