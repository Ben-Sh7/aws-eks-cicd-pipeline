import { ValidationPipe } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import helmet from 'helmet';

// Shared by main.ts and the e2e tests, so tests exercise the same pipeline.
export function configureApp(app: NestExpressApplication): void {
  // Every request arrives through the frontend, which forwards the browser's
  // address in X-Forwarded-For. It is trusted only from private addresses (the
  // cluster / compose network); without it, rate limiting would see a single
  // client - the frontend - and throttle all users together.
  app.set('trust proxy', 'loopback, linklocal, uniquelocal');
  app.use(helmet());
  app.setGlobalPrefix('api', { exclude: ['health'] });
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );
}
