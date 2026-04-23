import { z } from 'zod';

export const publishSignRequestSchema = z.object({
  // Studio / stream code. Becomes the RTMP stream name path component.
  studio: z
    .string()
    .min(1)
    .max(64)
    .regex(/^[a-zA-Z0-9_-]+$/, 'studio must be alphanumeric/underscore/dash'),
  expires_in: z.coerce.number().int().positive().optional(),
});

export type PublishSignRequestDto = z.infer<typeof publishSignRequestSchema>;
