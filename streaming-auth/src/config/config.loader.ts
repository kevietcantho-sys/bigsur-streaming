import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import * as yaml from 'js-yaml';
import { AppConfig, configSchema } from './config.schema';

/**
 * Resolve the config directory.
 * Looks for `./config/*.yaml` relative to cwd (works for both src/ and dist/ runs
 * because nest-cli copies `config/` into `dist/config/` on build).
 */
function resolveConfigDir(): string {
  const candidates = [
    process.env.CONFIG_DIR,
    resolve(process.cwd(), 'config'),
    resolve(process.cwd(), 'dist/config'),
    resolve(__dirname, '../../config'),
  ].filter(Boolean) as string[];

  for (const dir of candidates) {
    if (existsSync(resolve(dir, 'default.yaml'))) return dir;
  }
  throw new Error(
    `config/default.yaml not found. Tried: ${candidates.join(', ')}`,
  );
}

function loadYaml(path: string): Record<string, unknown> {
  if (!existsSync(path)) return {};
  const raw = readFileSync(path, 'utf8');
  const parsed = yaml.load(raw);
  if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
    return parsed as Record<string, unknown>;
  }
  return {};
}

function deepMerge<T extends Record<string, unknown>>(
  base: T,
  override: Record<string, unknown>,
): T {
  const out: Record<string, unknown> = { ...base };
  for (const [k, v] of Object.entries(override)) {
    if (v === undefined) continue;
    const existing = out[k];
    if (
      v && typeof v === 'object' && !Array.isArray(v) &&
      existing && typeof existing === 'object' && !Array.isArray(existing)
    ) {
      out[k] = deepMerge(existing as Record<string, unknown>, v as Record<string, unknown>);
    } else {
      out[k] = v;
    }
  }
  return out as T;
}

/**
 * Map selected env vars onto config tree. Only the env vars we advertise
 * are honored — keeps the override surface explicit.
 */
function envOverrides(env: NodeJS.ProcessEnv): Record<string, unknown> {
  const overrides: Record<string, unknown> = {
    nodeEnv: env.NODE_ENV,
    server: {
      port: env.PORT,
      bindIp: env.BIND_IP,
      trustProxy: env.TRUST_PROXY,
      bodyLimit: env.BODY_LIMIT,
    },
    cors: {
      origins: env.CORS_ORIGINS,
      methods: env.CORS_METHODS,
      headers: env.CORS_HEADERS,
    },
    sign: {
      minExpires: env.SIGN_MIN_EXPIRES,
      maxExpires: env.SIGN_MAX_EXPIRES,
      defaultExpires: env.SIGN_DEFAULT_EXPIRES,
      apiToken: env.SIGN_API_TOKEN,
      rateLimit: {
        ttl: env.SIGN_RATE_TTL,
        limit: env.SIGN_RATE_LIMIT,
      },
    },
    streams: {
      nameRegex: env.STREAMS_NAME_REGEX,
    },
    bunny: {
      cdnUrl: env.BUNNY_CDN_URL,
      tokenKey: env.BUNNY_TOKEN_KEY,
    },
    publish: {
      pushDomain: env.PUBLISH_DOMAIN,
      app: env.PUBLISH_APP,
      signKey: env.PUBLISH_SIGN_KEY,
      minExpires: env.PUBLISH_MIN_EXPIRES,
      maxExpires: env.PUBLISH_MAX_EXPIRES,
      defaultExpires: env.PUBLISH_DEFAULT_EXPIRES,
    },
    origin: {
      host: env.ORIGIN_HOST,
      port: env.ORIGIN_PORT,
    },
    logger: {
      level: env.LOG_LEVEL,
      format: env.LOG_FORMAT,
    },
  };
  return pruneUndefined(overrides);
}

function pruneUndefined(obj: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined) continue;
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      const inner = pruneUndefined(v as Record<string, unknown>);
      if (Object.keys(inner).length > 0) out[k] = inner;
    } else {
      out[k] = v;
    }
  }
  return out;
}

/**
 * Load + validate config. Precedence (low → high):
 *   default.yaml → <NODE_ENV>.yaml → env vars
 */
export function loadConfig(): AppConfig {
  const dir = resolveConfigDir();
  const base = loadYaml(resolve(dir, 'default.yaml'));
  const envName = process.env.NODE_ENV || 'production';
  const envYaml = loadYaml(resolve(dir, `${envName}.yaml`));

  const merged = deepMerge(
    deepMerge(base as Record<string, unknown>, envYaml),
    envOverrides(process.env),
  );

  // Secrets live only in env — inject if absent so the schema sees a string.
  const withSecrets = deepMerge(merged, {
    bunny: { tokenKey: process.env.BUNNY_TOKEN_KEY ?? '' },
    sign: { apiToken: process.env.SIGN_API_TOKEN ?? '' },
    publish: { signKey: process.env.PUBLISH_SIGN_KEY ?? '' },
  });

  const parsed = configSchema.safeParse(withSecrets);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `  • ${i.path.join('.') || '(root)'}: ${i.message}`)
      .join('\n');
    throw new Error(`Invalid configuration:\n${issues}`);
  }
  return parsed.data;
}

/** Nest @nestjs/config `load` factory */
export const configFactory = (): AppConfig => loadConfig();
