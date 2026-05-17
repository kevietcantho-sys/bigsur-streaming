import {
  Body,
  Controller,
  HttpCode,
  Post,
  Req,
  UseGuards,
  UsePipes,
} from '@nestjs/common';
import type { Request } from 'express';
import { ApiTokenGuard } from '../../common/guards/api-token.guard';
import { ZodValidationPipe } from '../../common/pipes/zod-validation.pipe';
import {
  PublishSignRequestDto,
  publishSignRequestSchema,
} from './dto/publish-sign-request.dto';
import {
  SignRequestDto,
  signRequestSchema,
} from './dto/sign-request.dto';
import { BigsurPublishService } from './bigsur-publish.service';
import { SignService } from './sign.service';

// Two signers:
//   POST /sign         — BunnyCDN playback URL (quick testing, see test.html)
//   POST /sign/publish — txSecret/txTime RTMP(S) push URL for OBS

@Controller('sign')
@UseGuards(ApiTokenGuard)
export class SignController {
  constructor(
    private readonly publishSigner: BigsurPublishService,
    private readonly playbackSigner: SignService,
  ) {}

  /** Playback URL signer — BunnyCDN token-auth signed HLS playlist URL. */
  @Post()
  @HttpCode(200)
  @UsePipes(new ZodValidationPipe(signRequestSchema))
  async sign(@Body() dto: SignRequestDto) {
    return this.playbackSigner.sign(dto);
  }

  /** Publish URL signer — txSecret/txTime RTMP(S) push URL for OBS. */
  @Post('publish')
  @HttpCode(200)
  @UsePipes(new ZodValidationPipe(publishSignRequestSchema))
  async signPublish(
    @Req() req: Request & { tenant?: string },
    @Body() dto: PublishSignRequestDto,
  ) {
    return this.publishSigner.sign(req.tenant!, dto.studio, dto.expires_in ?? 0);
  }
}
