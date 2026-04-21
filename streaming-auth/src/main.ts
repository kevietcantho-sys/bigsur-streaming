import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { Logger as PinoLogger } from 'nestjs-pino';
import type { NestExpressApplication } from '@nestjs/platform-express';

import { AppModule } from './app.module';
import { AppConfigService } from './config/app-config.service';

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    bufferLogs: true,
  });
  app.useLogger(app.get(PinoLogger));

  const config = app.get(AppConfigService);

  app.disable('x-powered-by');
  app.set('trust proxy', config.server.trustProxy);

  app.enableCors({
    origin:
      config.cors.origins === '*'
        ? true
        : config.cors.origins.split(',').map((s) => s.trim()).filter(Boolean),
    methods: config.cors.methods,
    allowedHeaders: config.cors.headers,
  });

  // Graceful shutdown on SIGTERM/SIGINT
  app.enableShutdownHooks();

  await app.listen(config.server.port, config.server.bindIp);

  const logger = app.get(PinoLogger);
  logger.log(
    `streaming-auth listening on ${config.server.bindIp}:${config.server.port} (env=${config.nodeEnv})`,
    'Bootstrap',
  );
}

bootstrap().catch((err) => {
  // eslint-disable-next-line no-console
  console.error('[FATAL] bootstrap failed:', err?.message ?? err);
  process.exit(1);
});
