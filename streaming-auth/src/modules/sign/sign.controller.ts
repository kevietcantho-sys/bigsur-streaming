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
import { BigsurPublishService } from './bigsur-publish.service';

// Playback URL signing (POST /sign) was removed: clients now generate
// BunnyCDN signed URLs locally with their own (pull_zone, token_key) pair.
// SignService + BunnyService + sign-request.dto remain in the tree as
// reference for the signing algorithm.

@Controller('sign')
@UseGuards(ApiTokenGuard)
export class SignController {
  constructor(private readonly publishSigner: BigsurPublishService) {}

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
