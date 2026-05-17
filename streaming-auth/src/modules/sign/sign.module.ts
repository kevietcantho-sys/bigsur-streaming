import { Module } from '@nestjs/common';
import { StreamsModule } from '../streams/streams.module';
import { SignController } from './sign.controller';
import { BigsurPublishService } from './bigsur-publish.service';
import { SignService } from './sign.service';
import { BunnyService } from './bunny.service';

// SignService + BunnyService are registered so POST /sign can mint BunnyCDN
// playback URLs server-side — used for quick testing (see test.html).
// Requires BUNNY_CDN_URL + BUNNY_TOKEN_KEY in the service .env.

@Module({
  imports: [StreamsModule],
  controllers: [SignController],
  providers: [BigsurPublishService, SignService, BunnyService],
  exports: [BigsurPublishService],
})
export class SignModule {}
