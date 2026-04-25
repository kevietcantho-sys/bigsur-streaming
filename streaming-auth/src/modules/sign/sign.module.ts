import { Module } from '@nestjs/common';
import { StreamsModule } from '../streams/streams.module';
import { SignController } from './sign.controller';
import { BigsurPublishService } from './bigsur-publish.service';

// SignService and BunnyService are intentionally NOT registered here —
// playback URL signing moved to clients. Files are kept in the tree as
// reference for the BunnyCDN token-auth algorithm.

@Module({
  imports: [StreamsModule],
  controllers: [SignController],
  providers: [BigsurPublishService],
  exports: [BigsurPublishService],
})
export class SignModule {}
