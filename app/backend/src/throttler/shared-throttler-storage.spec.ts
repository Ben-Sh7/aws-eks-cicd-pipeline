import { Logger } from '@nestjs/common';
import {
  type ThrottlerStorage,
  ThrottlerStorageService,
} from '@nestjs/throttler';
import {
  createThrottlerStorage,
  SharedThrottlerStorage,
} from './shared-throttler-storage';

const record = (totalHits: number) => ({
  totalHits,
  timeToExpire: 60,
  isBlocked: false,
  timeToBlockExpire: 0,
});

describe('SharedThrottlerStorage', () => {
  let increment: jest.MockedFunction<ThrottlerStorage['increment']>;
  let close: jest.MockedFunction<() => Promise<unknown>>;
  let warn: jest.SpyInstance;
  let log: jest.SpyInstance;
  let storage: SharedThrottlerStorage;

  beforeEach(() => {
    increment = jest.fn<
      ReturnType<ThrottlerStorage['increment']>,
      Parameters<ThrottlerStorage['increment']>
    >();
    close = jest.fn<Promise<unknown>, []>().mockResolvedValue('OK');
    storage = new SharedThrottlerStorage(
      { increment },
      new ThrottlerStorageService(),
      close,
    );
    warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation();
    log = jest.spyOn(Logger.prototype, 'log').mockImplementation();
  });

  afterEach(async () => {
    await storage.onApplicationShutdown();
    jest.restoreAllMocks();
  });

  it('counts in Redis while Redis answers', async () => {
    increment.mockResolvedValue(record(7));

    await expect(
      storage.increment('ip', 60_000, 20, 60_000, 'default'),
    ).resolves.toEqual(record(7));
    expect(increment).toHaveBeenCalledWith('ip', 60_000, 20, 60_000, 'default');
  });

  it('counts in memory when Redis fails, and says so once', async () => {
    increment.mockRejectedValue(new Error('Connection is closed.'));

    await storage.increment('ip', 60_000, 20, 60_000, 'default');
    const second = await storage.increment('ip', 60_000, 20, 60_000, 'default');

    expect(second.totalHits).toBe(2);
    expect(warn).toHaveBeenCalledTimes(1);
  });

  it('goes back to Redis once it answers again', async () => {
    increment
      .mockRejectedValueOnce(new Error('Command timed out'))
      .mockResolvedValueOnce(record(1));

    await storage.increment('ip', 60_000, 20, 60_000, 'default');
    const after = await storage.increment('ip', 60_000, 20, 60_000, 'default');

    expect(after).toEqual(record(1));
    expect(log).toHaveBeenCalledTimes(1);
  });

  it('closes the Redis connection on shutdown', async () => {
    await storage.onApplicationShutdown();

    expect(close).toHaveBeenCalled();
  });
});

describe('createThrottlerStorage', () => {
  it('leaves the counts in memory when no Redis host is set', () => {
    expect(createThrottlerStorage({ port: 6379 })).toBeUndefined();
  });
});
