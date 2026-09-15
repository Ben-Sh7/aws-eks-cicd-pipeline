import { Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import type { Env } from '../config/env.validation';
import { buildDataSourceOptions } from './data-source-options';
import { MigrationService } from './migration.service';

@Module({
  imports: [
    TypeOrmModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService<Env, true>) => ({
        ...buildDataSourceOptions({
          DB_HOST: config.get('DB_HOST', { infer: true }),
          DB_PORT: config.get('DB_PORT', { infer: true }),
          DB_NAME: config.get('DB_NAME', { infer: true }),
          DB_USER: config.get('DB_USER', { infer: true }),
          DB_PASSWORD: config.get('DB_PASSWORD', { infer: true }),
          DB_SSL_CA: config.get('DB_SSL_CA', { infer: true }),
        }),
        // The database may still be starting (compose, a fresh RDS instance).
        retryAttempts: 10,
        retryDelay: 3000,
      }),
    }),
  ],
  providers: [MigrationService],
})
export class DatabaseModule {}
