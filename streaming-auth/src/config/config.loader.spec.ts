import { loadConfig } from './config.loader';

const ORIGINAL_ENV = { ...process.env };

function setEnv(env: Record<string, string | undefined>) {
  process.env = { ...ORIGINAL_ENV, ...env } as NodeJS.ProcessEnv;
}

afterEach(() => { process.env = { ...ORIGINAL_ENV } as NodeJS.ProcessEnv; });

describe('loadConfig', () => {
  it('loads defaults', () => {
    setEnv({
      NODE_ENV: 'test',
      LOG_LEVEL: 'error',
    });
    const cfg = loadConfig();
    expect(cfg.server.port).toBe(3000);
    expect(cfg.streams.nameRegex).toMatch(/^/);
    // Per-tenant secrets (SIGN_API_TOKEN_<TENANT>, PUBLISH_SIGN_KEY_<TENANT>)
    // are validated by TenantsService at boot, not by the YAML/zod schema.
  });

  it('env PORT overrides YAML default', () => {
    setEnv({
      PORT: '4100',
      NODE_ENV: 'test',
    });
    expect(loadConfig().server.port).toBe(4100);
  });
});
