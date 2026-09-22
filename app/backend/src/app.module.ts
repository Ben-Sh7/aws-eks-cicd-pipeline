import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { AuthModule } from './auth/auth.module';
import { JwtAuthGuard } from './auth/jwt-auth.guard';
import { validateEnv } from './config/env.validation';
import { DatabaseModule } from './database/database.module';
import { HealthModule } from './health/health.module';
import { LoggingModule } from './logging/logging.module';
import { MetricsModule } from './metrics/metrics.module';
import { TasksModule } from './tasks/tasks.module';

@Module({
  imports: [
    // Real environment variables always win over the optional local .env file,
    // which only exists for `npm run start:dev`.
    ConfigModule.forRoot({
      isGlobal: true,
      cache: true,
      validate: validateEnv,
    }),
    ThrottlerModule.forRoot([{ ttl: 60_000, limit: 300 }]),
    LoggingModule,
    MetricsModule,
    DatabaseModule,
    AuthModule,
    TasksModule,
    HealthModule,
  ],
  providers: [
    // Guards run in this order: floods are cut off before any JWT is verified.
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    { provide: APP_GUARD, useClass: JwtAuthGuard },
  ],
})
export class AppModule {}
