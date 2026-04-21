import { StreamsService } from './streams.service';
import { AppConfigService } from '../../config/app-config.service';
import { StreamKeysRepository } from './stream-keys.repository';

function buildService(keys: Record<string, string>) {
  const config = {
    streams: { nameRegex: '^[a-zA-Z0-9_-]{1,64}$', keys },
  } as unknown as AppConfigService;

  const repo: StreamKeysRepository = {
    findSecret: async (n: string) => keys[n] ?? null,
    count: async () => Object.keys(keys).length,
  };

  return new StreamsService(config, repo);
}

describe('StreamsService.checkPublish', () => {
  const svc = buildService({ studio1: 'secret1', studio2: 'secret2' });

  it('allows when name+key match', async () => {
    const r = await svc.checkPublish('studio1', '?key=secret1');
    expect(r).toEqual({ allowed: true });
  });

  it('denies on unknown stream', async () => {
    const r = await svc.checkPublish('ghost', '?key=whatever');
    expect(r.allowed).toBe(false);
  });

  it('denies on wrong key', async () => {
    const r = await svc.checkPublish('studio1', '?key=nope');
    expect(r.allowed).toBe(false);
    expect(r.reason).toBe('bad key');
  });

  it('denies invalid stream names', async () => {
    const r = await svc.checkPublish('foo/bar', '?key=whatever');
    expect(r.allowed).toBe(false);
    expect(r.reason).toBe('invalid stream');
  });

  it('denies when no key supplied', async () => {
    const r = await svc.checkPublish('studio1', '');
    expect(r.allowed).toBe(false);
  });
});
