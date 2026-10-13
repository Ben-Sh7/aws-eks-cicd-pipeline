import { Logger, type OnApplicationShutdown } from '@nestjs/common';
import {
  type ThrottlerStorage,
  ThrottlerStorageService,
} from '@nestjs/throttler';
import { ThrottlerStorageRedisService } from '@nest-lab/throttler-storage-redis';
import Redis from 'ioredis';

type ThrottlerRecord = Awaited<ReturnType<ThrottlerStorage['increment']>>;

export interface RedisSettings {
  host?: string;
  port: number;
  password?: string;
}

// Counts in Redis, so every backend pod enforces one shared limit. When Redis
// does not answer, this pod counts in its own memory until it does: the limit
// is looser for that time, but sign-in keeps working.
export class SharedThrottlerStorage
  implements ThrottlerStorage, OnApplicationShutdown
{
  private readonly logger = new Logger(SharedThrottlerStorage.name);
  private counting = 'shared' as 'shared' | 'local';

  constructor(
    private readonly shared: ThrottlerStorage,
    private readonly local: ThrottlerStorageService,
    private readonly closeShared: () => Promise<unknown>,
  ) {}

  async increment(
    key: string,
    ttl: number,
    limit: number,
    blockDuration: number,
    throttlerName: string,
  ): Promise<ThrottlerRecord> {
    try {
      const record = await this.shared.increment(
        key,
        ttl,
        limit,
        blockDuration,
        throttlerName,
      );
      if (this.counting === 'local') {
        this.counting = 'shared';
        this.logger.log('Redis answers again: rate limits are shared');
      }
      return record;
    } catch (error) {
      if (this.counting === 'shared') {
        this.counting = 'local';
        this.logger.warn(
          `Redis did not answer (${(error as Error).message}): counting in this pod's memory until it does`,
        );
      }
      return this.local.increment(
        key,
        ttl,
        limit,
        blockDuration,
        throttlerName,
      );
    }
  }

  async onApplicationShutdown(): Promise<void> {
    this.local.onApplicationShutdown();
    await this.closeShared().catch(() => undefined);
  }
}

// No host keeps the counts in this process's memory - one instance, or the tests.
export function createThrottlerStorage(
  settings: RedisSettings,
): ThrottlerStorage | undefined {
  if (!settings.host) {
    return undefined;
  }

  const redis = new Redis({
    host: settings.host,
    port: settings.port,
    password: settings.password,
    // Fail at once while disconnected instead of queueing, so a request
    // falls back to local counting rather than waiting for Redis.
    enableOfflineQueue: false,
    maxRetriesPerRequest: 0,
    connectTimeout: 2000,
    commandTimeout: 500,
  });
  // ioredis prints every failed reconnect unless something listens; the
  // storage logs the outage once instead.
  redis.on('error', () => undefined);

  return new SharedThrottlerStorage(
    new ThrottlerStorageRedisService(redis),
    new ThrottlerStorageService(),
    () => redis.quit(),
  );
}
