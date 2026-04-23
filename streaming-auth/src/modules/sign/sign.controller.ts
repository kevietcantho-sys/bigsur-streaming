import {
  Body,
  Controller,
  HttpCode,
  Post,
  UseGuards,
  UsePipes,
} from '@nestjs/common';
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
import { SignService } from './sign.service';
import { TencentPublishService } from './tencent-publish.service';

@Controller('sign')
@UseGuards(ApiTokenGuard)
export class SignController {
  constructor(
    private readonly signService: SignService,
    private readonly publishSigner: TencentPublishService,
  ) {}

  /** Playback URL signer — BunnyCDN token-authenticated HLS manifest. */
  @Post()
  @HttpCode(200)
  @UsePipes(new ZodValidationPipe(signRequestSchema))
  sign(@Body() dto: SignRequestDto) {
    return this.signService.sign(dto);
  }

  /** Publish URL signer — TencentCloud-CSS-style RTMP push URL for OBS. */
  @Post('publish')
  @HttpCode(200)
  @UsePipes(new ZodValidationPipe(publishSignRequestSchema))
  signPublish(@Body() dto: PublishSignRequestDto) {
    return this.publishSigner.sign(dto.studio, dto.expires_in ?? 0);
  }
}
