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
   * Scheme: token = base64url(md5(tokenKey + tokenPath + expires [+ viewer_ip])).
   * See BunnyCDN-Auth-Production-Guide.docx for the reference.
   *
   * The token is embedded in the PATH (a `bcdn_token=...&expires=...&token_path=...`
   * prefix before the playlist path) rather than the query string. Relative HLS
   * segment URLs then resolve WITH the token attached, so native HLS players
   * (Safari/iOS) authenticate every segment automatically — no per-request token
   * injection needed in the player.
   */
  signPlaylist(stream: string, expiresIn: number, viewerIp?: string): SignedUrl {
    const { cdnUrl, tokenKey } = this.config.bunny;
    const { app } = this.config.publish;
    const expires = Math.floor(Date.now() / 1000) + expiresIn;
    // SRS writes HLS under the RTMP app name (PUBLISH_APP), so the playlist and
    // the BunnyCDN directory token both live at /<app>/. CDN requires
    // token_path to be an ABSOLUTE directory (leading + trailing slash) and the
    // file path must start with it; the SAME string feeds the hash, the file
    // path, and the token_path param.
    const tokenPath = `/${app.replace(/^\/+|\/+$/g, '')}/`;
    const playlistPath = `${tokenPath}${stream}.m3u8`;

    let hashInput = tokenKey + tokenPath + expires;
    if (viewerIp) hashInput += viewerIp;

    const token = createHash('md5')
      .update(hashInput)
      .digest()
      .toString('base64')
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=/g, '');

    const base = cdnUrl.replace(/\/+$/, '');
    const url =
      `${base}` +
      `/bcdn_token=${token}` +
      `&expires=${expires}` +
      `&token_path=${encodeURIComponent(tokenPath)}` +
      `${playlistPath}`;

    return { url, expires, expires_at: new Date(expires * 1000).toISOString() };
  }
}
