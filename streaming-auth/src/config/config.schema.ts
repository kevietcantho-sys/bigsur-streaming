import { z } from 'zod';

const streamKeysSchema = z
  .string()
  .transform((raw, ctx) => {
    const map: Record<string, string> = {};
    for (const pair of raw.split(',').map((s) => s.trim()).filter(Boolean)) {
      const [name, secret] = pair.split(':').map((s) => s?.trim());
      if (!name || !secret) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: `Invalid STREAM_KEYS entry: "${pair}" (expected name:secret)`,
        });
        return z.NEVER;
      }
      map[name] = secret;
    }
    if (Object.keys(map).length === 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'STREAM_KEYS must define at least one stream',
      });
      return z.NEVER;
    }
    return map;
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

  sign: z.object({
    minExpires: z.coerce.number().int().positive(),
    maxExpires: z.coerce.number().int().positive(),
    defaultExpires: z.coerce.number().int().positive(),
    rateLimit: z.object({
      ttl: z.coerce.number().int().positive(),
      limit: z.coerce.number().int().positive(),
    }),
    apiToken: z.string().min(16, 'SIGN_API_TOKEN must be at least 16 chars'),
  }).refine(
    (v) => v.minExpires <= v.defaultExpires && v.defaultExpires <= v.maxExpires,
    { message: 'sign expires bounds must satisfy min <= default <= max' },
  ),

  streams: z.object({
    nameRegex: z.string().min(1),
    // Parsed from STREAM_KEYS env
    keys: streamKeysSchema,
  }),

  bunny: z.object({
    cdnUrl: z.string(),       // may be empty → /sign fails closed (503)
    tokenKey: z.string(),     // may be empty → /sign fails closed (503)
  }),

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
