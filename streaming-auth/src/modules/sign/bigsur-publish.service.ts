import { Injectable, ServiceUnavailableException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { AppConfigService } from '../../config/app-config.service';
import { PushKeyResolver } from '../streams/push-key.resolver';

export interface SignedPublishUrl {
  url: string;             // rtmp://… (always present)
  url_rtmps?: string;      // rtmps://…:<port>/… (only when PUBLISH_RTMPS_ENABLED=true)
  stream: string;
  txTime: string;          // lowercase hex of unix-seconds expiry
  txSecret: string;        // md5(signKey + stream + txTime)
  expires: number;         // unix seconds
  expires_at: string;      // iso8601
}

/**
 * Mint a signed RTMP push URL (txSecret/txTime scheme).
 *
 * Format: rtmp://<pushDomain>/<app>/<stream>?txSecret=<md5>&txTime=<hex>
 * Scheme: txSecret = md5(signKey + stream + txTime), txTime = hex(unix_expires).
 *
 * RTMPS variant is only emitted when PUBLISH_RTMPS_ENABLED is set, since
 * RTMPS on :1936 only works if the deploy issued a Let's Encrypt cert
 * for $PUBLISH_HOST (the Cloudflare Origin Cert is rejected by OBS).
 *
 * SRS's on_publish hook (StreamsService.checkPublish) recomputes the same
 * md5 via PushKeyResolver to validate incoming publishes.
 */
@Injectable()
export class BigsurPublishService {
  constructor(
    private readonly config: AppConfigService,
    private readonly pushKeys: PushKeyResolver,
  ) {}

  async sign(studio: string, expiresIn: number): Promise<SignedPublishUrl> {
    if (!this.config.publishReady) {
      throw new ServiceUnavailableException({
        error: 'publish_not_configured',
        hint: 'Set PUBLISH_DOMAIN and PUBLISH_SIGN_KEY',
      });
    }

    const signKey = await this.pushKeys.resolve(studio);
    if (!signKey) {
      throw new ServiceUnavailableException({
        error: 'publish_not_configured',
        hint: 'No push key available for this studio',
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
    const stream = studio;

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
