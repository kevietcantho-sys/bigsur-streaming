import { Injectable } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { AppConfigService } from '../../config/app-config.service';

export interface SignedUrl {
  url: string;
  expires: number;        // unix seconds
  expires_at: string;     // iso8601
}

@Injectable()
export class BunnyService {
  constructor(private readonly config: AppConfigService) {}

  /**
   * Mint a BunnyCDN Token-Authenticated URL.
   * Scheme: md5(tokenKey + tokenPath + expires [+ viewer_ip]) base64url-no-pad.
   * See BunnyCDN-Auth-Production-Guide.docx for the reference.
   */
  signPlaylist(stream: string, expiresIn: number, viewerIp?: string): SignedUrl {
    const { cdnUrl, tokenKey } = this.config.bunny;
    const expires = Math.floor(Date.now() / 1000) + expiresIn;
    const playlistPath = `/live/${stream}.m3u8`;
    const tokenPath = `/live/`;

    let hashInput = tokenKey + tokenPath + expires;
    if (viewerIp) hashInput += viewerIp;

    const token = createHash('md5')
      .update(hashInput)
      .digest()
      .toString('base64')
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=/g, '');

    const url =
      `${cdnUrl}${playlistPath}` +
      `?token=${token}` +
      `&token_path=${encodeURIComponent(tokenPath)}` +
      `&expires=${expires}`;

    return { url, expires, expires_at: new Date(expires * 1000).toISOString() };
  }
}
