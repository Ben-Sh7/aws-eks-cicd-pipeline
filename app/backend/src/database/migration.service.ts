import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { DataSource } from 'typeorm';

// Arbitrary, but identical in every replica: that is what makes it a mutex.
const MIGRATION_LOCK_KEY = 4_817_263_509;

// Runs pending migrations during module init, which Nest completes before the
// HTTP server starts listening - so a pod never passes readiness on an old
// schema. Replicas that start together queue on a Postgres advisory lock
// instead of racing each other through the same migration.
@Injectable()
export class MigrationService implements OnModuleInit {
  private readonly logger = new Logger(MigrationService.name);

  constructor(private readonly dataSource: DataSource) {}

  async onModuleInit(): Promise<void> {
    // Advisory locks belong to a database session, so the lock is taken and
    // released on one dedicated connection. Releasing that connection back to
    // the pool would not free the lock; only the explicit unlock does.
    const lockRunner = this.dataSource.createQueryRunner();
    await lockRunner.connect();
    try {
      await lockRunner.query('SELECT pg_advisory_lock($1)', [
        MIGRATION_LOCK_KEY,
      ]);
      const applied = await this.dataSource.runMigrations({
        transaction: 'each',
      });
      for (const migration of applied) {
        this.logger.log(`Applied migration ${migration.name}`);
      }
    } finally {
      await lockRunner.query('SELECT pg_advisory_unlock($1)', [
        MIGRATION_LOCK_KEY,
      ]);
      await lockRunner.release();
    }
  }
}
