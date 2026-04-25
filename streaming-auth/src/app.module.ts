import { Module } from '@nestjs/common';
import { APP_FILTER } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { APP_GUARD } from '@nestjs/core';
import { LoggerModule } from 'nestjs-pino';

import { AppConfigModule } from './config/config.module';
import { AppConfigService } from './config/app-config.service';
import { AllExceptionsFilter } from './common/filters/all-exceptions.filter';
import { HealthModule } from './modules/health/health.module';
import { StreamsModule } from './modules/streams/streams.module';
import { SignModule } from './modules/sign/sign.module';
import { TenantsModule } from './modules/tenants/tenants.module';

@Module({
  imports: [
    AppConfigModule,

    LoggerModule.forRootAsync({
      inject: [AppConfigService],
      useFactory: (config: AppConfigService) => ({
        pinoHttp: {
          level: config.logger.level,
          transport:
            config.logger.format === 'pretty'
              ? { target: 'pino-pretty', options: { singleLine: true } }
              : undefined,
          redact: {
            paths: [
              'req.headers.authorization',
              'req.headers.cookie',
              'res.headers["set-cookie"]',
            ],
            censor: '[redacted]',
          },
          customProps: () => ({ service: 'streaming-auth' }),
        },
      }),
    }),

    ThrottlerModule.forRootAsync({
      inject: [AppConfigService],
      useFactory: (config: AppConfigService) => [
        {
          name: 'sign',
          ttl: config.sign.rateLimit.ttl,
          limit: config.sign.rateLimit.limit,
        },
      ],
    }),

    TenantsModule,
    HealthModule,
    StreamsModule,
    SignModule,
  ],
  providers: [
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    { provide: APP_FILTER, useClass: AllExceptionsFilter },
  ],
})
export class AppModule {}
