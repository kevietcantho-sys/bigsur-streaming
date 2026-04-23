import { Injectable, ServiceUnavailableException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { AppConfigService } from '../../config/app-config.service';

export interface SignedPublishUrl {
  url: string;
  stream: string;
  txTime: string;        // lowercase hex of unix-seconds expiry
  txSecret: string;      // md5(signKey + stream + txTime)
  expires: number;       // unix seconds
  expires_at: string;    // iso8601
}

/**
 * Mint a TencentCloud-CSS-style signed RTMP publish URL.
 *
 * Format: rtmp://<pushDomain>/<app>/<stream>?txSecret=<md5>&txTime=<hex>
 * Scheme: txSecret = md5(signKey + stream + txTime), txTime = hex(unix_expires).
 *
 * Tokens are stateless — SRS's on_publish hook recomputes the same md5 to
 * validate incoming publishes (see streams.controller for the validator).
 */
@Injectable()
export class TencentPublishService {
  constructor(private readonly config: AppConfigService) {}

  sign(studio: string, expiresIn: number): SignedPublishUrl {
    if (!this.config.publishReady) {
      throw new ServiceUnavailableException({
        error: 'publish_not_configured',
        hint: 'Set PUBLISH_DOMAIN and PUBLISH_SIGN_KEY',
      });
    }

    const { pushDomain, app, signKey, minExpires, maxExpires, defaultExpires } =
      this.config.publish;

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

    const url = `rtmp://${pushDomain}/${app}/${stream}?txSecret=${txSecret}&txTime=${txTime}`;

    return {
      url,
      stream,
      txTime,
      txSecret,
      expires,
      expires_at: new Date(expires * 1000).toISOString(),
    };
  }
}
