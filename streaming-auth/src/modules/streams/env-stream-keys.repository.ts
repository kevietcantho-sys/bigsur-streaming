import { Injectable } from '@nestjs/common';
import { AppConfigService } from '../../config/app-config.service';
import { StreamKeysRepository } from './stream-keys.repository';

/**
 * Default impl: stream keys come from the parsed STREAM_KEYS env var
 * (validated and indexed by ConfigSchema). Zero-latency in-memory lookup.
 */
@Injectable()
export class EnvStreamKeysRepository extends StreamKeysRepository {
  constructor(private readonly config: AppConfigService) { super(); }

  async findSecret(name: string): Promise<string | null> {
    return this.config.streams.keys[name] ?? null;
  }

  async count(): Promise<number> {
    return Object.keys(this.config.streams.keys).length;
  }
}
