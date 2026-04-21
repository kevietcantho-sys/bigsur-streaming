import { Body, Controller, HttpCode, Logger, Post } from '@nestjs/common';
import { SkipThrottle } from '@nestjs/throttler';
import { StreamsService } from './streams.service';

/**
 * SRS-facing webhook endpoints. SRS expects `{code: 0}` for allow,
 * non-zero for deny — we always reply 200 and use body code per SRS spec.
 * Reachable only over VPC (firewalled at HAProxy box).
 */
@SkipThrottle()
@Controller('srs')
export class StreamsController {
  private readonly logger = new Logger(StreamsController.name);

  constructor(private readonly streams: StreamsService) {}

  @Post('publish')
  @HttpCode(200)
  async onPublish(
    @Body() body: { stream?: unknown; param?: unknown } | undefined,
  ): Promise<{ code: number; data?: string }> {
    const result = await this.streams.checkPublish(body?.stream, body?.param);
    return result.allowed
      ? { code: 0, data: 'OK' }
      : { code: 403, data: result.reason ?? 'denied' };
  }

  @Post('unpublish')
  @HttpCode(200)
  async onUnpublish(
    @Body() body: { stream?: unknown } | undefined,
  ): Promise<{ code: number }> {
    this.logger.log(`DONE ${body?.stream ?? '(unknown)'}`);
    return { code: 0 };
  }
}
