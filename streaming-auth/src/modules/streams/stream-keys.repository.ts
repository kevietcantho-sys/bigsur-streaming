/**
 * Stream-key lookup abstraction. Swap the implementation to move from
 * env-based config → DB-backed (Postgres/Redis/etc.) without touching
 * controllers or services.
 */
export abstract class StreamKeysRepository {
  abstract findSecret(streamName: string): Promise<string | null>;
  abstract count(): Promise<number>;
}

export const STREAM_KEYS_REPOSITORY = Symbol('STREAM_KEYS_REPOSITORY');
