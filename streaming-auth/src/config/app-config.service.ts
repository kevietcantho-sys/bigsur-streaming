import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { AppConfig } from './config.schema';

/**
 * Thin typed wrapper around Nest's ConfigService so callers get full
 * type-safety without repeating `configService.get<T>(...)` everywhere.
 */
@Injectable()
export class AppConfigService {
  constructor(private readonly raw: ConfigService) {}

  private get cfg(): AppConfig {
    // Our load factory returns the whole AppConfig as the root object,
    // so every top-level key is accessible via get<T>('key').
    return {
      nodeEnv: this.raw.getOrThrow('nodeEnv'),
      server: this.raw.getOrThrow('server'),
      cors: this.raw.getOrThrow('cors'),
      sign: this.raw.getOrThrow('sign'),
      streams: this.raw.getOrThrow('streams'),
      bunny: this.raw.getOrThrow('bunny'),
      publish: this.raw.getOrThrow('publish'),
      origin: this.raw.getOrThrow('origin'),
      logger: this.raw.getOrThrow('logger'),
    };
  }

  get nodeEnv() { return this.cfg.nodeEnv; }
  get server()  { return this.cfg.server; }
  get cors()    { return this.cfg.cors; }
  get sign()    { return this.cfg.sign; }
  get streams() { return this.cfg.streams; }
  get bunny()   { return this.cfg.bunny; }
  get publish() { return this.cfg.publish; }
  get origin()  { return this.cfg.origin; }
  get logger()  { return this.cfg.logger; }

  /** True when Bunny is fully configured; /sign returns 503 otherwise. */
  get bunnyReady(): boolean {
    return Boolean(this.cfg.bunny.cdnUrl && this.cfg.bunny.tokenKey);
  }

  /** True when the shared publish ingress is configured. Per-tenant push
   *  keys are checked separately by PushKeyResolver / TenantsService. */
  get publishReady(): boolean {
    return Boolean(this.cfg.publish.pushDomain);
  }
}
