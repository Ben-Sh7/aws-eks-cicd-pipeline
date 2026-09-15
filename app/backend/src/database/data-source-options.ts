import { readFileSync } from 'node:fs';
import type { DataSourceOptions } from 'typeorm';
import { RefreshToken } from '../auth/refresh-token.entity';
import type { Env } from '../config/env.validation';
import { Task } from '../tasks/task.entity';
import { User } from '../users/user.entity';
import { InitialSchema1789430400000 } from './migrations/1789430400000-initial-schema';
import { AddPasswordAuth1789479000000 } from './migrations/1789479000000-add-password-auth';

export type DatabaseEnv = Pick<
  Env,
  'DB_HOST' | 'DB_PORT' | 'DB_NAME' | 'DB_USER' | 'DB_PASSWORD' | 'DB_SSL_CA'
>;

export function buildDataSourceOptions(env: DatabaseEnv): DataSourceOptions {
  return {
    type: 'postgres',
    host: env.DB_HOST,
    port: env.DB_PORT,
    database: env.DB_NAME,
    username: env.DB_USER,
    password: env.DB_PASSWORD,
    // RDS runs with rds.force_ssl=1. The server certificate is verified against
    // the CA bundle baked into the image instead of being accepted blindly.
    ssl: env.DB_SSL_CA
      ? { ca: readFileSync(env.DB_SSL_CA, 'utf8'), rejectUnauthorized: true }
      : false,
    entities: [User, Task, RefreshToken],
    // Listed explicitly rather than globbed, so the same list works from the
    // TypeScript sources (tests) and the compiled output (dist).
    migrations: [InitialSchema1789430400000, AddPasswordAuth1789479000000],
    // The schema only ever changes through migrations - see MigrationService.
    synchronize: false,
    migrationsRun: false,
  };
}
