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
  SignRequestDto,
  signRequestSchema,
} from './dto/sign-request.dto';
import { SignService } from './sign.service';

@Controller('sign')
@UseGuards(ApiTokenGuard)
export class SignController {
  constructor(private readonly signService: SignService) {}

  @Post()
  @HttpCode(200)
  @UsePipes(new ZodValidationPipe(signRequestSchema))
  sign(@Body() dto: SignRequestDto) {
    return this.signService.sign(dto);
  }
}
