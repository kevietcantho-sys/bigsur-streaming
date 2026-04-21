import { z } from 'zod';

export const signRequestSchema = z.object({
  stream: z
    .string()
    .min(1)
    .max(64)
    .regex(/^[a-zA-Z0-9_-]+$/, 'stream must be alphanumeric/underscore/dash'),
  expires_in: z.coerce.number().int().positive().optional(),
  viewer_ip: z
    .string()
    .max(45)
    .regex(/^[0-9a-fA-F:.]+$/, 'viewer_ip must be IPv4 or IPv6')
    .optional(),
});

export type SignRequestDto = z.infer<typeof signRequestSchema>;
