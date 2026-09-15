// The e2e suite truncates tables, so it refuses to run against any database
// whose name does not end in _e2e. It never touches the development database.
const E2E_DB_NAME = /^[a-z0-9_]+_e2e$/;

export function applyE2eEnv(): void {
  process.env.DB_HOST ??= 'localhost';
  process.env.DB_PORT ??= '5432';
  process.env.DB_USER ??= 'postgres';
  process.env.DB_NAME = process.env.E2E_DB_NAME ?? 'tasksdb_e2e';
  process.env.DB_SSL_CA = '';
  process.env.JWT_SECRET = 'e2e-only-jwt-secret-that-is-long-enough-000';
  process.env.GOOGLE_CLIENT_ID = 'e2e-client-id';

  if (!E2E_DB_NAME.test(process.env.DB_NAME)) {
    throw new Error(
      `Refusing to run e2e tests against "${process.env.DB_NAME}": the name must end in _e2e`,
    );
  }
  if (!process.env.DB_PASSWORD) {
    throw new Error(
      'Set DB_PASSWORD to the local Postgres password to run the e2e tests',
    );
  }
}

applyE2eEnv();
