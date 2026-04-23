import { Module } from '@nestjs/common';
import { StreamsModule } from '../streams/streams.module';
import { BunnyService } from './bunny.service';
import { SignController } from './sign.controller';
import { SignService } from './sign.service';
import { TencentPublishService } from './tencent-publish.service';

@Module({
  imports: [StreamsModule],
  controllers: [SignController],
  providers: [SignService, BunnyService, TencentPublishService],
  exports: [SignService, BunnyService, TencentPublishService],
})
export class SignModule {}
