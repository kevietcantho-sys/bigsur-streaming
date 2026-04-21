import {
  Injectable,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { AppConfigService } from '../../config/app-config.service';
import { StreamKeysRepository } from '../streams/stream-keys.repository';
import { BunnyService, SignedUrl } from './bunny.service';
import { SignRequestDto } from './dto/sign-request.dto';

@Injectable()
export class SignService {
  constructor(
    private readonly config: AppConfigService,
    private readonly repo: StreamKeysRepository,
    private readonly bunny: BunnyService,
  ) {}

  async sign(dto: SignRequestDto): Promise<SignedUrl> {
    // Fail-closed when BunnyCDN unconfigured (matches legacy behavior)
    if (!this.config.bunnyReady) {
      throw new ServiceUnavailableException({
        error: 'cdn_not_configured',
        hint: 'Set BUNNY_TOKEN_KEY and BUNNY_CDN_URL',
      });
    }

    const secret = await this.repo.findSecret(dto.stream);
    if (!secret) {
      throw new NotFoundException({ error: 'stream not found' });
    }

    const { minExpires, maxExpires, defaultExpires } = this.config.sign;
    const requested = dto.expires_in ?? defaultExpires;
    const expiresIn = Math.max(minExpires, Math.min(maxExpires, requested));

    return this.bunny.signPlaylist(dto.stream, expiresIn, dto.viewer_ip);
  }
}
