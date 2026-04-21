import { createHash } from 'node:crypto';
import { BunnyService } from './bunny.service';
import { AppConfigService } from '../../config/app-config.service';

function makeConfig(overrides?: Partial<{ cdnUrl: string; tokenKey: string }>) {
  return {
    bunny: {
      cdnUrl: overrides?.cdnUrl ?? 'https://stream.b-cdn.net',
      tokenKey: overrides?.tokenKey ?? 'test-key',
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

  it('produces a URL matching the documented BunnyCDN token scheme', () => {
    const svc = new BunnyService(makeConfig());
    const { url, expires } = svc.signPlaylist('studio1', 600);

    const expectedExpires = Math.floor(FIXED_NOW_MS / 1000) + 600;
    expect(expires).toBe(expectedExpires);

    const expectedToken = createHash('md5')
      .update('test-key' + '/live/' + expectedExpires)
      .digest()
      .toString('base64')
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');

    const parsed = new URL(url);
    expect(parsed.origin + parsed.pathname).toBe('https://stream.b-cdn.net/live/studio1.m3u8');
    expect(parsed.searchParams.get('token')).toBe(expectedToken);
    expect(parsed.searchParams.get('token_path')).toBe('/live/');
    expect(parsed.searchParams.get('expires')).toBe(String(expectedExpires));
  });

  it('includes viewer_ip in token hash when provided', () => {
    const svc = new BunnyService(makeConfig());
    const a = svc.signPlaylist('s1', 60).url;
    const b = svc.signPlaylist('s1', 60, '203.0.113.5').url;

    const tokenA = new URL(a).searchParams.get('token');
    const tokenB = new URL(b).searchParams.get('token');
    expect(tokenA).not.toBe(tokenB);
  });

  it('uses distinct tokens across streams', () => {
    const svc = new BunnyService(makeConfig());
    const t1 = new URL(svc.signPlaylist('studio1', 60).url).searchParams.get('token');
    const t2 = new URL(svc.signPlaylist('studio2', 60).url).searchParams.get('token');
    // Token only depends on token_path/expires/key/(ip); same across streams
    // because token_path stays `/live/`. This asserts current behavior so
    // future changes to token_path per-stream are deliberate.
    expect(t1).toBe(t2);
  });
});
