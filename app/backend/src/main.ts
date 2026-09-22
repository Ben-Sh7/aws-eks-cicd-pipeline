import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Logger } from 'nestjs-pino';
import { AppModule } from './app.module';
import { configureApp } from './app.setup';
import type { Env } from './config/env.validation';

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    bufferLogs: true,
  });
  // Everything Nest itself logs goes through pino too, so the output is JSON
  // from the first line rather than from the first request.
  app.useLogger(app.get(Logger));
  configureApp(app);
  // Closes DB connections cleanly on SIGTERM during rolling updates.
  app.enableShutdownHooks();

  const config = app.get<ConfigService<Env, true>>(ConfigService);
  await app.listen(config.get('PORT', { infer: true }));
}

void bootstrap();
