import { Module } from '@nestjs/common';
import { StreamsController } from './streams.controller';
import { StreamsService } from './streams.service';
import { StreamKeysRepository } from './stream-keys.repository';
import { EnvStreamKeysRepository } from './env-stream-keys.repository';
import { PushKeyResolver } from './push-key.resolver';
import { EnvPushKeyResolver } from './env-push-key.resolver';

@Module({
  controllers: [StreamsController],
  providers: [
    StreamsService,
    { provide: StreamKeysRepository, useClass: EnvStreamKeysRepository },
    { provide: PushKeyResolver, useClass: EnvPushKeyResolver },
  ],
  exports: [StreamsService, StreamKeysRepository, PushKeyResolver],
})
export class StreamsModule {}
