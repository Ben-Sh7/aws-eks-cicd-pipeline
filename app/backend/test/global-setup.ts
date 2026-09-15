import { Client } from 'pg';
import { applyE2eEnv } from './e2e-env';

// Creates the dedicated e2e database on the local Postgres if it is missing.
// Migrations then run inside it when the app boots, exactly as in production.
export default async function globalSetup(): Promise<void> {
  applyE2eEnv();
  const client = new Client({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT),
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: 'postgres',
  });
  await client.connect();
  try {
    const databaseName = process.env.DB_NAME as string;
    const existing = await client.query(
      'SELECT 1 FROM pg_database WHERE datname = $1',
      [databaseName],
    );
    if (existing.rowCount === 0) {
      // Identifiers cannot be bound as parameters; applyE2eEnv already
      // restricted the name to [a-z0-9_].
      await client.query(`CREATE DATABASE "${databaseName}"`);
    }
  } finally {
    await client.end();
  }
}
