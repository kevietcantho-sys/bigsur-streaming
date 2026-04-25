import { Module } from '@nestjs/common';
import { StreamsController } from './streams.controller';
import { StreamsService } from './streams.service';
import { PushKeyResolver } from './push-key.resolver';
import { EnvPushKeyResolver } from './env-push-key.resolver';

@Module({
  controllers: [StreamsController],
  providers: [
    StreamsService,
    { provide: PushKeyResolver, useClass: EnvPushKeyResolver },
  ],
  exports: [StreamsService, PushKeyResolver],
})
export class StreamsModule {}
