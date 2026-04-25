import { createHash } from 'node:crypto';
import { StreamsService } from './streams.service';
import { AppConfigService } from '../../config/app-config.service';
import { PushKeyResolver } from './push-key.resolver';

const SIGN_KEY = 'push-secret';

function buildService(signKey: string | null = SIGN_KEY) {
  const config = {
    streams: { nameRegex: '^[a-zA-Z0-9_-]{1,64}$', keys: {} },
  } as unknown as AppConfigService;

  const resolver: PushKeyResolver = {
    resolve: async () => signKey,
  };

  return new StreamsService(config, resolver);
}

function mintParam(stream: string, key: string, expiresAtSec: number): string {
  const txTime = expiresAtSec.toString(16);
  const txSecret = createHash('md5').update(key + stream + txTime).digest('hex');
  return `?txSecret=${txSecret}&txTime=${txTime}`;
}

describe('StreamsService.checkPublish', () => {
  const svc = buildService();
  const now = () => Math.floor(Date.now() / 1000);

  it('allows when txSecret + txTime match the push key', async () => {
    const stream = 'LR-MNC3HOF8-5A9F04';
    const r = await svc.checkPublish(
      stream,
      mintParam(stream, SIGN_KEY, now() + 600),
    );
    expect(r).toEqual({ allowed: true });
  });

  it('denies on bad signature', async () => {
    const stream = 'studio1';
    const r = await svc.checkPublish(
      stream,
      mintParam(stream, 'wrong-key', now() + 600),
    );
    expect(r.allowed).toBe(false);
    expect(r.reason).toBe('bad signature');
  });

  it('denies when txTime is in the past', async () => {
    const stream = 'studio1';
    const r = await svc.checkPublish(
      stream,
      mintParam(stream, SIGN_KEY, now() - 60),
    );
    expect(r.allowed).toBe(false);
    expect(r.reason).toBe('expired');
  });

  it('denies on malformed txTime', async () => {
    const stream = 'studio1';
    const r = await svc.checkPublish(
      stream,
      '?txSecret=' + 'a'.repeat(32) + '&txTime=zzzz',
    );
    expect(r.allowed).toBe(false);
    expect(r.reason).toBe('invalid txTime');
  });

  it('denies invalid stream names', async () => {
    const r = await svc.checkPublish('foo/bar', '?txSecret=x&txTime=1');
    expect(r.allowed).toBe(false);
    expect(r.reason).toBe('invalid stream');
  });

  it('denies when no signature supplied', async () => {
    const r = await svc.checkPublish('studio1', '');
    expect(r.allowed).toBe(false);
    expect(r.reason).toBe('missing signature');
  });

  it('denies when push key is not configured', async () => {
    const noKey = buildService(null);
    const stream = 'studio1';
    const r = await noKey.checkPublish(
      stream,
      mintParam(stream, SIGN_KEY, now() + 600),
    );
    expect(r.allowed).toBe(false);
    expect(r.reason).toBe('no key');
  });

  it('accepts uppercase-hex txSecret (constant-time compare is case-insensitive on hex)', async () => {
    const stream = 'studio1';
    const expires = now() + 600;
    const txTime = expires.toString(16);
    const txSecret = createHash('md5')
      .update(SIGN_KEY + stream + txTime)
      .digest('hex')
      .toUpperCase();
    const r = await svc.checkPublish(
      stream,
      `?txSecret=${txSecret}&txTime=${txTime}`,
    );
    expect(r).toEqual({ allowed: true });
  });
});
