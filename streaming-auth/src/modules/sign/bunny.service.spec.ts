import { createHash } from 'node:crypto';
import { BunnyService } from './bunny.service';
import { AppConfigService } from '../../config/app-config.service';

function makeConfig(
  overrides?: Partial<{ cdnUrl: string; tokenKey: string; app: string }>,
) {
  return {
    bunny: {
      cdnUrl: overrides?.cdnUrl ?? 'https://stream.b-cdn.net',
      tokenKey: overrides?.tokenKey ?? 'test-key',
    },
    publish: {
      app: overrides?.app ?? 'luckylive',
    },
    get bunnyReady() {
      return Boolean(this.bunny.cdnUrl && this.bunny.tokenKey);
    },
  } as unknown as AppConfigService;
}

describe('BunnyService', () => {
  let realNow: () => number;
  const FIXED_NOW_MS = 1_700_000_000_000;

  beforeAll(() => {
    realNow = Date.now;
    Date.now = () => FIXED_NOW_MS;
  });
  afterAll(() => { Date.now = realNow; });

  // Path-based token: `<base>/bcdn_token=<token>&expires=<n>&token_path=<dir>/<dir>/<stream>.m3u8`.
  const TOKEN_RE =
    /^bcdn_token=([^&]+)&expires=(\d+)&token_path=([^/]+)$/;
  function parseSigned(url: string) {
    const u = new URL(url);
    const segments = u.pathname.replace(/^\//, '').split('/');
    const prefix = segments.shift() ?? '';
    const m = TOKEN_RE.exec(prefix);
    return {
      origin: u.origin,
      token: m?.[1],
      expires: m?.[2],
      tokenPath: m ? decodeURIComponent(m[3]) : undefined,
      filePath: `/${segments.join('/')}`,
    };
  }

  it('produces a path-based BunnyCDN token URL', () => {
    const svc = new BunnyService(makeConfig());
    const { url, expires } = svc.signPlaylist('studio1', 600);

    const expectedExpires = Math.floor(FIXED_NOW_MS / 1000) + 600;
    expect(expires).toBe(expectedExpires);

    const expectedToken = createHash('md5')
      .update('test-key' + '/luckylive/' + expectedExpires)
      .digest()
      .toString('base64')
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');

    const parsed = parseSigned(url);
    expect(parsed.origin).toBe('https://stream.b-cdn.net');
    expect(parsed.token).toBe(expectedToken);
    expect(parsed.expires).toBe(String(expectedExpires));
    expect(parsed.tokenPath).toBe('/luckylive/');
    // File path follows the token prefix and starts with the token_path dir.
    expect(parsed.filePath).toBe('/luckylive/studio1.m3u8');
  });

  it('includes viewer_ip in token hash when provided', () => {
    const svc = new BunnyService(makeConfig());
    const a = svc.signPlaylist('s1', 60).url;
    const b = svc.signPlaylist('s1', 60, '203.0.113.5').url;

    expect(parseSigned(a).token).not.toBe(parseSigned(b).token);
  });

  it('uses identical tokens across streams (token scoped to token_path)', () => {
    const svc = new BunnyService(makeConfig());
    const t1 = parseSigned(svc.signPlaylist('studio1', 60).url).token;
    const t2 = parseSigned(svc.signPlaylist('studio2', 60).url).token;
    // Token only depends on token_path/expires/key/(ip); same across streams
    // because token_path stays `/<app>/`. This asserts current behavior so
    // future changes to token_path per-stream are deliberate.
    expect(t1).toBe(t2);
  });
});
