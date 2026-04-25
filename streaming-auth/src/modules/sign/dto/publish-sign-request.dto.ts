import { z } from 'zod';

// Studio is the tenant-scoped suffix only (no `__`). The auth service
// prepends the bearer's tenant id at sign time, so callers cannot spoof
// another tenant's prefix even if they know the format.
export const publishSignRequestSchema = z.object({
  studio: z
    .string()
    .min(1)
    .max(48)
    .regex(/^[a-zA-Z0-9_-]+$/, 'studio must be alphanumeric/underscore/dash')
    .refine((s) => !s.includes('__'), 'studio must not contain "__" (tenant separator)'),
  expires_in: z.coerce.number().int().positive().optional(),
});

export type PublishSignRequestDto = z.infer<typeof publishSignRequestSchema>;
