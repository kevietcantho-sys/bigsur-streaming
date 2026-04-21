import { Controller, Get } from '@nestjs/common';
import { SkipThrottle } from '@nestjs/throttler';
import { AppConfigService } from '../../config/app-config.service';

@SkipThrottle()
@Controller('health')
export class HealthController {
  constructor(private readonly config: AppConfigService) {}

  @Get()
  health() {
    return {
      status: 'ok',
      streams: Object.keys(this.config.streams.keys).length,
      cdn: this.config.bunnyReady ? 'configured' : 'pending',
    };
  }
}
