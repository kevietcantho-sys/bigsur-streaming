import { loadConfig } from './config.loader';

const ORIGINAL_ENV = { ...process.env };

function setEnv(env: Record<string, string | undefined>) {
  process.env = { ...ORIGINAL_ENV, ...env } as NodeJS.ProcessEnv;
}

afterEach(() => { process.env = { ...ORIGINAL_ENV } as NodeJS.ProcessEnv; });

describe('loadConfig', () => {
  it('loads defaults + required env secrets', () => {
    setEnv({
      SIGN_API_TOKEN: 'a'.repeat(64),
      BUNNY_TOKEN_KEY: 'bunny',
      BUNNY_CDN_URL: 'https://x.b-cdn.net',
      NODE_ENV: 'test',
      LOG_LEVEL: 'error',
    });
    const cfg = loadConfig();
    expect(cfg.server.port).toBe(3000);
    expect(cfg.streams.nameRegex).toMatch(/^/);
    expect(cfg.bunny.cdnUrl).toBe('https://x.b-cdn.net');
    expect(cfg.sign.apiToken.length).toBeGreaterThanOrEqual(16);
  });

  it('rejects too-short SIGN_API_TOKEN', () => {
    setEnv({
      SIGN_API_TOKEN: 'short',
      NODE_ENV: 'test',
    });
    expect(() => loadConfig()).toThrow(/SIGN_API_TOKEN/);
  });

  it('env PORT overrides YAML default', () => {
    setEnv({
      SIGN_API_TOKEN: 'a'.repeat(64),
      PORT: '4100',
      NODE_ENV: 'test',
    });
    expect(loadConfig().server.port).toBe(4100);
  });
});
