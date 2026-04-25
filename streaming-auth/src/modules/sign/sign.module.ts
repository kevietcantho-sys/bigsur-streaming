import { Module } from '@nestjs/common';
import { StreamsModule } from '../streams/streams.module';
import { BunnyService } from './bunny.service';
import { SignController } from './sign.controller';
import { SignService } from './sign.service';
import { BigsurPublishService } from './bigsur-publish.service';

@Module({
  imports: [StreamsModule],
  controllers: [SignController],
  providers: [SignService, BunnyService, BigsurPublishService],
  exports: [SignService, BunnyService, BigsurPublishService],
})
export class SignModule {}
