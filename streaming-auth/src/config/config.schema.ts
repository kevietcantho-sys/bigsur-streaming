import { z } from 'zod';

// Env vars arrive as strings — coerce common truthy/falsy literals.
// `z.coerce.boolean()` is a footgun (any non-empty string → true).
const envBoolSchema = z
  .union([z.boolean(), z.string()])
  .transform((v) => {
    if (typeof v === 'boolean') return v;
    return /^(1|true|yes|on)$/i.test(v.trim());
  });

const byteSizeSchema = z
  .string()
  .regex(/^\d+(b|kb|mb)$/i, 'bodyLimit must look like "16kb"');

export const configSchema = z.object({
  nodeEnv: z.enum(['development', 'production', 'test']).default('production'),

  server: z.object({
    port: z.coerce.number().int().min(1).max(65535),
    bindIp: z.string().min(1),
    trustProxy: z.coerce.number().int().min(0).max(10),
    bodyLimit: byteSizeSchema,
  }),

  cors: z.object({
    origins: z.string(),
    methods: z.string(),
    headers: z.string(),
  }),

  // Bearer tokens for /sign/publish are per-tenant (SIGN_API_TOKEN_<TENANT>),
  // loaded by TenantsService at boot. Only sizing/rate-limit knobs live here.
  sign: z.object({
    minExpires: z.coerce.number().int().positive(),
    maxExpires: z.coerce.number().int().positive(),
    defaultExpires: z.coerce.number().int().positive(),
    rateLimit: z.object({
      ttl: z.coerce.number().int().positive(),
      limit: z.coerce.number().int().positive(),
    }),
  }).refine(
    (v) => v.minExpires <= v.defaultExpires && v.defaultExpires <= v.maxExpires,
    { message: 'sign expires bounds must satisfy min <= default <= max' },
  ),

  streams: z.object({
    nameRegex: z.string().min(1),
  }),

  bunny: z.object({
    cdnUrl: z.string(),       // may be empty → /sign fails closed (503)
    tokenKey: z.string(),     // may be empty → /sign fails closed (503)
  }),

  // Publish-URL signing (txSecret/txTime).
  // pushDomain is the shared RTMP ingest hostname (one per deployment);
  // per-tenant signing keys live in TenantsService (PUBLISH_SIGN_KEY_<TENANT>).
  // rtmpsEnabled gates the optional `url_rtmps` field — only flip on when
  // a Let's Encrypt cert is bound to :rtmpsPort (else OBS rejects the cert).
  publish: z.object({
    pushDomain: z.string(),
    app: z.string().min(1),
    minExpires: z.coerce.number().int().positive(),
    maxExpires: z.coerce.number().int().positive(),
    defaultExpires: z.coerce.number().int().positive(),
    rtmpsEnabled: envBoolSchema.default(false),
    rtmpsPort: z.coerce.number().int().min(1).max(65535).default(1936),
  }).refine(
    (v) => v.minExpires <= v.defaultExpires && v.defaultExpires <= v.maxExpires,
    { message: 'publish expires bounds must satisfy min <= default <= max' },
  ),

  origin: z.object({
    host: z.string(),
    port: z.coerce.number().int().min(1).max(65535),
  }),

  logger: z.object({
    level: z.enum(['trace', 'debug', 'info', 'warn', 'error', 'fatal']),
    format: z.enum(['json', 'pretty']),
  }),
});

export type AppConfig = z.infer<typeof configSchema>;
