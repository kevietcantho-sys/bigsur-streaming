import { Module } from '@nestjs/common';
import { StreamsController } from './streams.controller';
import { StreamsService } from './streams.service';
import { StreamKeysRepository } from './stream-keys.repository';
import { EnvStreamKeysRepository } from './env-stream-keys.repository';

@Module({
  controllers: [StreamsController],
  providers: [
    StreamsService,
    { provide: StreamKeysRepository, useClass: EnvStreamKeysRepository },
  ],
  exports: [StreamsService, StreamKeysRepository],
})
export class StreamsModule {}
