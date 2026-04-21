import { Module } from '@nestjs/common';
import { StreamsModule } from '../streams/streams.module';
import { BunnyService } from './bunny.service';
import { SignController } from './sign.controller';
import { SignService } from './sign.service';

@Module({
  imports: [StreamsModule],
  controllers: [SignController],
  providers: [SignService, BunnyService],
  exports: [SignService, BunnyService],
})
export class SignModule {}
